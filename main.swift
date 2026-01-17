import Cocoa
import ScreenCaptureKit
import AVFoundation
import Foundation
import SwiftUI
import Combine

class WindowRecorderCore: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingURL: URL?
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var stream: SCStream?
    private var streamOutput: StreamCaptureHelper?
    
    func startRecording(window: SCWindow) async throws {
        guard !isRecording else { return }
        
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = availableContent.displays.first else {
            throw RecordingError.noDisplayAvailable
        }
        
        let contentFilter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.sourceRect = window.frame
        configuration.capturesAudio = false
        configuration.showsCursor = false
        
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let fileName = "Recording_\(Int(Date().timeIntervalSince1970)).mp4"
        recordingURL = desktopPath.appendingPathComponent(fileName)
        
        assetWriter = try AVAssetWriter(outputURL: recordingURL!, fileType: .mp4)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(window.frame.width),
            AVVideoHeightKey: Int(window.frame.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6000000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        
        if assetWriter?.canAdd(videoInput!) == true {
            assetWriter?.add(videoInput!)
        } else {
            throw RecordingError.cannotAddVideoInput
        }
        
        stream = SCStream(filter: contentFilter, configuration: configuration, delegate: self)
        streamOutput = StreamCaptureHelper()
        streamOutput?.recorder = self
        
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: DispatchQueue(label: "recording.queue"))
        try await stream?.startCapture()
        
        if assetWriter?.startWriting() == true {
            assetWriter?.startSession(atSourceTime: .zero)
            await MainActor.run {
                isRecording = true
            }
        } else {
            throw RecordingError.cannotStartWriting
        }
        
        print("🎬 Recording started: \(recordingURL!.path)")
    }
    
    func stopRecording() async {
        guard isRecording else { return }
        
        do {
            try await stream?.stopCapture()
        } catch {
            print("Error stopping stream: \(error)")
        }
        
        videoInput?.markAsFinished()
        await assetWriter?.finishWriting()
        
        await MainActor.run {
            isRecording = false
            if let url = recordingURL {
                print("✅ Recording saved: \(url.path)")
                
                let alert = NSAlert()
                alert.messageText = "Recording Complete"
                alert.informativeText = "Recording saved to Desktop:\n\(url.lastPathComponent)"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            }
        }
    }
    
    func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, videoInput?.isReadyForMoreMediaData == true else { return }
        videoInput?.append(sampleBuffer)
    }
}

extension WindowRecorderCore: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
        Task {
            await MainActor.run {
                isRecording = false
            }
        }
    }
}

class StreamCaptureHelper: NSObject, SCStreamOutput {
    weak var recorder: WindowRecorderCore?
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        recorder?.handleSampleBuffer(sampleBuffer)
    }
}

enum RecordingError: Error, LocalizedError {
    case noDisplayAvailable
    case cannotAddVideoInput
    case cannotStartWriting
    
    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for recording"
        case .cannotAddVideoInput:
            return "Cannot add video input to asset writer"
        case .cannotStartWriting:
            return "Cannot start asset writer"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var window: NSWindow?
    var recorder: WindowRecorderCore?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupStatusBar()
        setupMainWindow()
        requestScreenRecordingPermission()
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Window Recorder")
            button.action = #selector(showMainWindow)
            button.target = self
        }
    }
    
    @objc func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    func setupMainWindow() {
        let rect = NSRect(x: 100, y: 100, width: 600, height: 500)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Window Recorder"
        window?.center()
        
        let recorder = WindowRecorderCore()
        let contentView = MainView(recorder: recorder)
        let hostingView = NSHostingView(rootView: contentView)
        window?.contentView = hostingView
        
        window?.makeKeyAndOrderFront(nil)
    }
    
    func requestScreenRecordingPermission() {
        let authorized = CGPreflightScreenCaptureAccess()
        if !authorized {
            CGRequestScreenCaptureAccess()
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}

struct MainView: View {
    @ObservedObject var recorder: WindowRecorderCore
    @State private var availableWindows: [SCWindow] = []
    @State private var selectedWindow: SCWindow?
    @State private var errorMessage = ""
    @State private var showingError = false
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Window Recorder")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top)
            
            if isLoading {
                ProgressView("Loading windows...")
                    .padding()
            } else if recorder.isRecording {
                recordingView
            } else {
                setupView
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            Task {
                await getAvailableWindows()
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
    
    var recordingView: some View {
        VStack(spacing: 20) {
            if let window = selectedWindow {
                VStack {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.red)
                    
                    Text("Recording: \(window.title ?? "Unknown Window")")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("App: \(window.owningApplication?.applicationName ?? "Unknown App")")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(12)
            }
            
            Button(action: stopRecording) {
                HStack {
                    Image(systemName: "stop.circle.fill")
                    Text("Stop Recording")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.red)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    var setupView: some View {
        VStack(spacing: 20) {
            if availableWindows.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "window.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No windows available")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    Button("Refresh Windows") {
                        Task {
                            await getAvailableWindows()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Select a window to record:")
                        .font(.headline)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(availableWindows, id: \.windowID) { window in
                                WindowRow(window: window) {
                                    Task {
                                        await startRecording(window: window)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxHeight: 300)
                    
                    HStack {
                        Button("Refresh") {
                            Task {
                                await getAvailableWindows()
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Text("\(availableWindows.count) windows found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    func getAvailableWindows() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableWindows = availableContent.windows.filter { window in
                window.owningApplication != nil && 
                window.windowID != 0 && 
                window.title != nil && 
                !window.title!.isEmpty
            }.sorted { $0.title! < $1.title! }
        } catch {
            errorMessage = "Error getting windows: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    func startRecording(window: SCWindow) async {
        selectedWindow = window
        
        do {
            try await recorder.startRecording(window: window)
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    func stopRecording() {
        Task {
            await recorder.stopRecording()
            selectedWindow = nil
        }
    }
}

struct WindowRow: View {
    let window: SCWindow
    let onRecord: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "macwindow")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    
                    Text(window.title ?? "Untitled")
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                
                Text(window.owningApplication?.applicationName ?? "Unknown App")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onRecord) {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle")
                    Text("Record")
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue)
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()