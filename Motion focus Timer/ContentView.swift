import SwiftUI
import CoreMotion
import AVFoundation
import UserNotifications
import ActivityKit



// MARK: - Models
enum SessionState: String, Codable, CaseIterable {
    case inactive
    case active
    case warning
    case quitting
    case completed
}

struct SessionData: Codable {
    let id: UUID
    let startDate: Date
    let duration: TimeInterval
    var state: SessionState
    var interruptionCount: Int
    
    var endDate: Date {
        startDate.addingTimeInterval(duration)
    }
    
    var isExpired: Bool {
        Date() >= endDate
    }
    
    var remainingTime: TimeInterval {
        max(0, endDate.timeIntervalSince(Date()))
    }
    
    var elapsedTime: TimeInterval {
        min(duration, Date().timeIntervalSince(startDate))
    }
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, elapsedTime / duration)
    }
    
    init(duration: TimeInterval) {
        self.id = UUID()
        self.startDate = Date()
        self.duration = duration
        self.state = .active
        self.interruptionCount = 0
    }
}

// MARK: - Live Activity Support (iOS 16.1+)
@available(iOS 16.1, *)
struct FocusTimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var remainingTime: TimeInterval
        var totalDuration: TimeInterval
        var isCompleted: Bool
    }
    
    var sessionId: String
}

// MARK: - Motion Detection Manager
class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let movementThreshold: Double = 0.25
    private let debounceInterval: TimeInterval = 1.0
    private var lastMovementTime = Date.distantPast
    
    var isAvailable: Bool {
        motionManager.isDeviceMotionAvailable
    }
    
    var onMovementDetected: (() -> Void)?
    
    init() {
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.name = "MotionDetectionQueue"
    }
    
    func startDetection() {
        guard isAvailable else {
            print("Motion detection not available - running in soft mode")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 25.0
        
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            
            let acceleration = motion.userAcceleration
            let magnitude = sqrt(pow(acceleration.x, 2) + pow(acceleration.y, 2) + pow(acceleration.z, 2))
            
            if self.shouldTriggerMovementAlert(magnitude: magnitude) {
                DispatchQueue.main.async {
                    self.onMovementDetected?()
                }
            }
        }
    }
    
    func stopDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
    
    func shouldTriggerMovementAlert(magnitude: Double) -> Bool {
        let now = Date()
        let timeSinceLastMovement = now.timeIntervalSince(lastMovementTime)
        
        if magnitude > movementThreshold && timeSinceLastMovement > debounceInterval {
            lastMovementTime = now
            return true
        }
        return false
    }
}

// MARK: - Session Manager
class SessionManager: ObservableObject {
    @Published var currentSession: SessionData?
    @Published var sessionState: SessionState = .inactive
    @Published var showingSetupModal = false
    @Published var showingWarning = false
    @Published var showingQuitDialog = false
    @Published var quitProgress: Double = 0.0
    @Published var mathCaptcha: (question: String, answer: Int)?
    @Published var captchaInput: String = ""
    @Published var showingOnboarding = false
    
    private let motionManager = MotionManager()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .heavy)
    private var sessionTimer: Timer?
    private var quitTimer: Timer?
    private var lastWarningTime = Date.distantPast
    private let warningCooldown: TimeInterval = 10
    private var currentActivity: Any? // Changed to Any for iOS compatibility
    
    private let sessionDataKey = "focus_session_data"
    private let hasSeenOnboardingKey = "has_seen_onboarding"
    
    init() {
        setupMotionDetection()
        setupNotifications()
        
        if !UserDefaults.standard.bool(forKey: hasSeenOnboardingKey) {
            showingOnboarding = true
        }
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Setup
    private func setupMotionDetection() {
        motionManager.onMovementDetected = { [weak self] in
            self?.handleMovementDetected()
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    // MARK: - Session Control
    func startSession(duration: TimeInterval) {
        let session = SessionData(duration: duration)
        currentSession = session
        sessionState = .active
        
        motionManager.startDetection()
        UIApplication.shared.isIdleTimerDisabled = true
        
        startSessionTimer()
        persistSession()
        startLiveActivity(for: session)
        
        print("Focus session started: \(Int(duration/60)) minutes")
    }
    
    func resumeSession() {
        showingWarning = false
        sessionState = .active
        persistSession()
    }
    
    func beginQuitSession() {
        showingWarning = false
        showingQuitDialog = true
        sessionState = .quitting
        generateMathCaptcha()
    }
    
    func confirmQuit() {
        stopSession()
        sessionState = .inactive
        currentSession = nil
        showingQuitDialog = false
        clearPersistedSession()
    }
    
    func completeSession() {
        sessionState = .completed
        motionManager.stopDetection()
        UIApplication.shared.isIdleTimerDisabled = false
        
        let notificationFeedback = UINotificationFeedbackGenerator()
        notificationFeedback.notificationOccurred(.success)
        
        updateLiveActivity(completed: true)
        
        print("Focus session completed!")
    }
    
    private func stopSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        quitTimer?.invalidate()
        quitTimer = nil
        
        motionManager.stopDetection()
        UIApplication.shared.isIdleTimerDisabled = false
        
        endLiveActivity()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    // MARK: - Motion Handling
    private func handleMovementDetected() {
        guard sessionState == .active,
              Date().timeIntervalSince(lastWarningTime) > warningCooldown else {
            return
        }
        
        lastWarningTime = Date()
        currentSession?.interruptionCount += 1
        
        hapticFeedback.impactOccurred()
        
        showingWarning = true
        sessionState = .warning
        
        if UIApplication.shared.applicationState == .active {
            speakWarning()
        }
        
        persistSession()
        
        print("Movement detected - showing warning")
    }
    
    private func speakWarning() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        
        let utterance = AVSpeechUtterance(string: "Focus session is running — please put the phone back down.")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        
        speechSynthesizer.speak(utterance)
    }
    
    // MARK: - Math Captcha
    func generateMathCaptcha() {
        let num1 = Int.random(in: 10...20)
        let num2 = Int.random(in: 1...9)
        let operations = ["+", "-"]
        let operation = operations.randomElement()!
        
        let answer: Int
        let question: String
        
        switch operation {
        case "+":
            answer = num1 + num2
            question = "\(num1) + \(num2) = ?"
        default: // "-"
            answer = num1 - num2
            question = "\(num1) - \(num2) = ?"
        }
        
        mathCaptcha = (question, answer)
        captchaInput = ""
    }
    
    func validateCaptcha() -> Bool {
        guard let captcha = mathCaptcha,
              let userAnswer = Int(captchaInput) else {
            return false
        }
        return userAnswer == captcha.answer
    }
    
    // MARK: - Hold-to-Quit
    func startHoldToQuit() {
        quitProgress = 0.0
        quitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.quitProgress += 0.02
            
            if self.quitProgress >= 1.0 {
                self.quitTimer?.invalidate()
                self.confirmQuit()
            }
        }
    }
    
    func cancelHoldToQuit() {
        quitTimer?.invalidate()
        quitProgress = 0.0
    }
    
    // MARK: - Timers
    private func startSessionTimer() {
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let session = self.currentSession else {
                return
            }
            
            if session.isExpired {
                self.completeSession()
                return
            }
            
            self.objectWillChange.send()
            self.updateLiveActivity(completed: false)
        }
    }
    
    // MARK: - Persistence
    func persistSession() {
        guard let session = currentSession else { return }
        
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(session) {
            UserDefaults.standard.set(data, forKey: sessionDataKey)
            UserDefaults.standard.set(sessionState.rawValue, forKey: "focus_session_state")
        }
    }
    
    func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionDataKey),
              let session = try? JSONDecoder().decode(SessionData.self, from: data),
              let stateString = UserDefaults.standard.object(forKey: "focus_session_state") as? String,
              let state = SessionState(rawValue: stateString) else {
            return
        }
        
        if session.isExpired {
            clearPersistedSession()
            sessionState = .completed
            currentSession = session
            return
        }
        
        currentSession = session
        sessionState = state
        
        if state == .active {
            UIApplication.shared.isIdleTimerDisabled = true
            motionManager.startDetection()
            startSessionTimer()
            startLiveActivity(for: session)
        }
        
        print("Session restored: \(Int(session.remainingTime)) seconds remaining")
    }
    
    private func clearPersistedSession() {
        UserDefaults.standard.removeObject(forKey: sessionDataKey)
        UserDefaults.standard.removeObject(forKey: "focus_session_state")
    }
    
    // MARK: - Notifications
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    private func scheduleSessionEndNotification() {
        guard let session = currentSession else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Focus Session Complete!"
        content.body = "Your \(Int(session.duration/60))-minute focus session has ended."
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, session.remainingTime), repeats: false)
        let request = UNNotificationRequest(identifier: "focus_session_end", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Live Activity
    private func startLiveActivity(for session: SessionData) {
        if #available(iOS 16.1, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                print("Live Activities not enabled")
                return
            }
            
            let attributes = FocusTimerAttributes(sessionId: session.id.uuidString)
            let contentState = FocusTimerAttributes.ContentState(
                remainingTime: session.remainingTime,
                totalDuration: session.duration,
                isCompleted: false
            )
            
            do {
                currentActivity = try Activity<FocusTimerAttributes>.request(
                    attributes: attributes,
                    contentState: contentState
                )
                print("Live Activity started")
            } catch {
                print("Failed to start Live Activity: \(error)")
            }
        }
    }
    
    private func updateLiveActivity(completed: Bool) {
        if #available(iOS 16.1, *),
           let activity = currentActivity as? Activity<FocusTimerAttributes>,
           let session = currentSession {
            
            let contentState = FocusTimerAttributes.ContentState(
                remainingTime: session.remainingTime,
                totalDuration: session.duration,
                isCompleted: completed
            )
            
            Task {
                await activity.update(using: contentState)
            }
        }
    }
    
    private func endLiveActivity() {
        if #available(iOS 16.1, *),
           let activity = currentActivity as? Activity<FocusTimerAttributes> {
            Task {
                await activity.end(dismissalPolicy: .immediate)
                currentActivity = nil
            }
        }
    }
    
    // MARK: - App Lifecycle
    @objc private func appWillTerminate() {
        cleanup()
    }
    
    @objc private func appDidEnterBackground() {
        if sessionState == .active {
            scheduleSessionEndNotification()
        }
        motionManager.stopDetection()
        print("App entered background - motion detection stopped")
    }
    
    @objc private func appWillEnterForeground() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        
        if sessionState == .active {
            motionManager.startDetection()
            print("App entered foreground - motion detection resumed")
        }
        
        if let session = currentSession, session.isExpired {
            completeSession()
        }
    }
    
    private func cleanup() {
        stopSession()
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    // MARK: - Onboarding
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: hasSeenOnboardingKey)
        showingOnboarding = false
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.systemBackground).opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack {
                switch sessionManager.sessionState {
                case .inactive:
                    InactiveView()
                case .active:
                    ActiveTimerView()
                case .warning:
                    WarningView()
                case .quitting:
                    QuitDialogView()
                case .completed:
                    CompletedView()
                }
            }
        }
        .sheet(isPresented: $sessionManager.showingSetupModal) {
            SetupModalView()
        }
        .sheet(isPresented: $sessionManager.showingOnboarding) {
            OnboardingView()
        }
    }
}

// MARK: - Inactive View (Main Menu)
struct InactiveView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var selectedDuration: TimeInterval = 1500
    
    private let durations: [(String, TimeInterval)] = [
        ("15 min", 900),
        ("25 min", 1500),
        ("45 min", 2700),
        ("60 min", 3600),
        ("90 min", 5400)
    ]
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("Focus Timer")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Deep work sessions with gentle accountability")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            VStack(spacing: 16) {
                Text("Choose your focus duration")
                    .font(.headline)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(durations, id: \.0) { name, duration in
                        DurationButton(
                            name: name,
                            duration: duration,
                            isSelected: selectedDuration == duration
                        ) {
                            selectedDuration = duration
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            VStack(spacing: 16) {
                Button(action: {
                    sessionManager.showingSetupModal = true
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Focus Session")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.blue)
                    )
                }
                .padding(.horizontal)
                
                Button("Privacy & Info") {
                    sessionManager.showingOnboarding = true
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .onChange(of: sessionManager.showingSetupModal) { showing in
            if showing {
                // Pass selected duration to setup modal
                sessionManager.selectedDuration = selectedDuration
            }
        }
    }
}

// MARK: - Duration Button
struct DurationButton: View {
    let name: String
    let duration: TimeInterval
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? .blue : Color(.systemGray5))
                )
        }
    }
}

// MARK: - Setup Modal
struct SetupModalView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDuration: TimeInterval = 1500
    @State private var didPlacePhone = false
    
    private let durations: [(String, TimeInterval)] = [
        ("15 min", 900),
        ("25 min", 1500),
        ("45 min", 2700),
        ("60 min", 3600),
        ("90 min", 5400)
    ]
    
    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Image(systemName: "iphone")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("Setup Focus Session")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Choose your duration and prepare your workspace for deep focus.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 16) {
                Text("Session Duration")
                    .font(.headline)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(durations, id: \.0) { name, duration in
                        DurationButton(
                            name: name,
                            duration: duration,
                            isSelected: selectedDuration == duration
                        ) {
                            selectedDuration = duration
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 16) {
                Text("Preparation Steps:")
                    .font(.headline)
                
                InstructionRow(
                    icon: "arrow.down.circle.fill",
                    text: "Turn your phone face-down"
                )
                InstructionRow(
                    icon: "table",
                    text: "Place on a stable surface"
                )
                InstructionRow(
                    icon: "bell.slash.fill",
                    text: "Movement will trigger gentle warnings"
                )
            }
            .padding(.horizontal)
            
            Spacer()
            
            VStack(spacing: 16) {
                if !didPlacePhone {
                    Button("I've placed my phone face-down") {
                        didPlacePhone = true
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.blue)
                    )
                } else {
                    Button("Start \(Int(selectedDuration/60))-Minute Session") {
                        sessionManager.startSession(duration: selectedDuration)
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.green)
                    )
                }
                
                Button("Cancel") {
                    dismiss()
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - Instruction Row
struct InstructionRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            Text(text)
                .font(.body)
            
            Spacer()
        }
    }
}

// MARK: - Active Timer View
struct ActiveTimerView: View {
    @EnvironmentObject var sessionManager: SessionManager
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("Focus Session Active")
                    .font(.headline)
                    .foregroundColor(.green)
                
                Text("Keep your phone face-down")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if let session = sessionManager.currentSession {
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 8)
                        .frame(width: 280, height: 280)
                    
                    Circle()
                        .trim(from: 0, to: session.progress)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 280, height: 280)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: session.progress)
                    
                    VStack(spacing: 8) {
                        Text(formatTime(session.remainingTime))
                            .font(.system(size: 48, weight: .light, design: .rounded))
                            .monospacedDigit()
                        
                        Text("remaining")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let session = sessionManager.currentSession {
                HStack(spacing: 32) {
                    StatView(
                        label: "Duration",
                        value: "\(Int(session.duration/60)) min"
                    )
                    
                    StatView(
                        label: "Interruptions",
                        value: "\(session.interruptionCount)"
                    )
                }
            }
            
            Spacer()
            
            Button("End Session") {
                sessionManager.beginQuitSession()
            }
            .font(.footnote)
            .foregroundColor(.red)
            .padding(.bottom)
        }
        .padding()
    }
}

// MARK: - Stat View
struct StatView: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Warning View
struct WarningView: View {
    @EnvironmentObject var sessionManager: SessionManager
    
    var body: some View {
        ZStack {
            Color.red
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                Spacer()
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.white)
                
                VStack(spacing: 16) {
                    Text("Movement Detected!")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("Your focus session is still running.\nPlease put your phone back down.")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
                
                Spacer()
                
                VStack(spacing: 16) {
                    Button("I'm Returning") {
                        sessionManager.resumeSession()
                    }
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white)
                    )
                    
                    Button("Quit Session") {
                        sessionManager.beginQuitSession()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white, lineWidth: 2)
                    )
                }
                .padding(.horizontal, 32)
                
                Spacer()
            }
        }
    }
}

// MARK: - Quit Dialog View
struct QuitDialogView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var quitMethod: QuitMethod = .holdToQuit
    
    enum QuitMethod: CaseIterable {
        case holdToQuit
        case mathCaptcha
        
        var title: String {
            switch self {
            case .holdToQuit: return "Hold to Quit"
            case .mathCaptcha: return "Solve to Quit"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Text("Are you sure?")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("You're doing great! Consider going back to your focus session.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            if let session = sessionManager.currentSession {
                VStack(spacing: 12) {
                    HStack {
                        Text("Time focused:")
                        Spacer()
                        Text(formatTime(session.elapsedTime))
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Text("Interruptions:")
                        Spacer()
                        Text("\(session.interruptionCount)")
                            .fontWeight(.semibold)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
            
            Spacer()
            
            Picker("Quit Method", selection: $quitMethod) {
                ForEach(QuitMethod.allCases, id: \.self) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            Group {
                switch quitMethod {
                case .holdToQuit:
                    HoldToQuitView()
                case .mathCaptcha:
                    MathCaptchaView()
                }
            }
            
            Spacer()
            
            Button("Return to Session") {
                sessionManager.resumeSession()
            }
            .font(.headline)
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.blue, lineWidth: 2)
            )
            .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - Hold to Quit View
struct HoldToQuitView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var isHolding = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Hold to confirm quitting")
                .font(.headline)
            
            ZStack {
                Circle()
                    .stroke(Color(.systemGray4), lineWidth: 8)
                    .frame(width: 120, height: 120)
                
                Circle()
                    .trim(from: 0, to: sessionManager.quitProgress)
                    .stroke(.red, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: sessionManager.quitProgress)
                
                Text("HOLD")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(isHolding ? .red : .secondary)
            }
            .scaleEffect(isHolding ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHolding)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 50) {
                sessionManager.cancelHoldToQuit()
                isHolding = false
            } onPressingChanged: { pressing in
                isHolding = pressing
                if pressing {
                    sessionManager.startHoldToQuit()
                } else {
                    sessionManager.cancelHoldToQuit()
                }
            }
        }
    }
}

// MARK: - Math Captcha View
struct MathCaptchaView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var showError = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Solve to confirm quitting")
                .font(.headline)
            
            if let captcha = sessionManager.mathCaptcha {
                VStack(spacing: 12) {
                    Text(captcha.question)
                        .font(.title)
                        .fontWeight(.semibold)
                    
                    TextField("Your answer", text: $sessionManager.captchaInput)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 120)
                        .multilineTextAlignment(.center)
                    
                    if showError {
                        Text("Incorrect answer")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Button("Submit") {
                if sessionManager.validateCaptcha() {
                    sessionManager.confirmQuit()
                } else {
                    showError = true
                    sessionManager.generateMathCaptcha()
                    sessionManager.captchaInput = ""
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showError = false
                    }
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(width: 120)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.red)
            )
            .disabled(sessionManager.captchaInput.isEmpty)
        }
    }
}

// MARK: - Completed View
struct CompletedView: View {
    @EnvironmentObject var sessionManager: SessionManager
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.green)
                
                Text("Session Complete!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Great job staying focused!")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            if let session = sessionManager.currentSession {
                VStack(spacing: 16) {
                    StatCard(
                        title: "Focus Time",
                        value: formatTime(session.duration),
                        icon: "clock.fill",
                        color: .blue
                    )
                    
                    StatCard(
                        title: "Interruptions",
                        value: "\(session.interruptionCount)",
                        icon: "exclamationmark.triangle.fill",
                        color: session.interruptionCount == 0 ? .green : .orange
                    )
                    
                    if session.interruptionCount == 0 {
                        Text("Perfect session!")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                }
            }
            
            Spacer()
            
            Button("Start New Session") {
                sessionManager.sessionState = .inactive
                sessionManager.currentSession = nil
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.blue)
            )
            .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - Stat Card
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - Onboarding View
struct OnboardingView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Privacy & How It Works")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Focus Timer helps you maintain deep focus by gently discouraging phone usage during work sessions.")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    
                    FeatureSection(
                        title: "How It Works",
                        items: [
                            FeatureItem(
                                icon: "timer",
                                title: "Set Your Focus Time",
                                description: "Choose from 15 minutes to 90 minutes of focused work time."
                            ),
                            FeatureItem(
                                icon: "iphone.radiowaves.left.and.right",
                                title: "Motion Detection",
                                description: "When you pick up your phone, you'll get a gentle reminder to stay focused."
                            ),
                            FeatureItem(
                                icon: "speaker.wave.2.fill",
                                title: "Audio Feedback",
                                description: "Spoken reminders help you stay on track without looking at the screen."
                            ),
                            FeatureItem(
                                icon: "lock.shield",
                                title: "Thoughtful Friction",
                                description: "If you need to quit early, a small challenge helps you make an intentional choice."
                            )
                        ]
                    )
                    
                    FeatureSection(
                        title: "Your Privacy",
                        items: [
                            FeatureItem(
                                icon: "location.slash",
                                title: "No Location Tracking",
                                description: "Your location is never accessed or stored."
                            ),
                            FeatureItem(
                                icon: "wifi.slash",
                                title: "No Data Collection",
                                description: "Motion data is only used locally during active sessions. Nothing is uploaded to servers."
                            ),
                            FeatureItem(
                                icon: "moon.zzz",
                                title: "No Background Monitoring",
                                description: "Motion detection only works when the app is open and you're in an active session."
                            ),
                            FeatureItem(
                                icon: "trash",
                                title: "No Data Retention",
                                description: "Session data is deleted when you complete or quit a session."
                            )
                        ]
                    )
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Device Requirements")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("• iOS 16.0 or later\n• Device with accelerometer (all modern iPhones)\n• Notifications permission (optional, for session completion alerts)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        sessionManager.completeOnboarding()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Feature Section
struct FeatureSection: View {
    let title: String
    let items: [FeatureItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            
            VStack(spacing: 12) {
                ForEach(items, id: \.title) { item in
                    FeatureItemView(item: item)
                }
            }
        }
    }
}

// MARK: - Feature Item
struct FeatureItem {
    let icon: String
    let title: String
    let description: String
}

// MARK: - Feature Item View
struct FeatureItemView: View {
    let item: FeatureItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(item.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

// MARK: - Utility Functions
func formatTime(_ timeInterval: TimeInterval) -> String {
    let totalSeconds = Int(timeInterval)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - SessionManager Extension
extension SessionManager {
    var selectedDuration: TimeInterval {
        get { UserDefaults.standard.double(forKey: "selected_duration") }
        set { UserDefaults.standard.set(newValue, forKey: "selected_duration") }
    }
}
