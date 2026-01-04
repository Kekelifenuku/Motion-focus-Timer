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
                .presentationDetents([.large])

                      .presentationDragIndicator(.visible)
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
    @State private var currentQuoteIndex = 0
    @State private var isAnimatingQuote = false
    
    private let durations: [(String, TimeInterval)] = [
        ("15 min", 900),
        ("25 min", 1500),
        ("45 min", 2700),
        ("60 min", 3600),
        ("90 min", 5400)
    ]
    
    private let motivationalQuotes = [
        "Discipline is choosing between what you want now and what you want most.",
        "Small daily disciplines compound into remarkable results.",
        "Discipline is the bridge between goals and accomplishment.",
        "Self-discipline begins with mastery of your thoughts.",
        "Discipline is doing what needs to be done, even when you don't want to.",
        "Consistent discipline creates lasting freedom.",
        "Discipline is the foundation upon which all success is built.",
        "The pain of discipline is less than the pain of regret.",
        "Discipline is remembering what you want.",
        "Master your minutes, master your life.",
        "Discipline equals freedom.",
        "Routine sets the stage for excellence.",
        "Discipline is the highest form of self-love.",
        "No discipline, no destiny.",
        "Discipline is the soul of productivity.",
        "Consistency is the hallmark of discipline.",
        "Discipline turns talent into achievement.",
        "Self-control is strength. Right thought is mastery.",
        "Discipline is the key to unlocking potential.",
        "Daily discipline creates extraordinary results."
    ]
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("Owl Focus")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Deep work sessions with gentle accountability")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Motivational Quote Card
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "quote.opening")
                        .font(.caption)
                        .foregroundColor(.blue.opacity(0.7))
                    
                    Spacer()
                    
                    Image(systemName: "quote.closing")
                        .font(.caption)
                        .foregroundColor(.blue.opacity(0.7))
                }
                
                Text(motivationalQuotes[currentQuoteIndex])
                    .font(.body)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .padding(.horizontal)
                    .opacity(isAnimatingQuote ? 1 : 0)
                    .offset(y: isAnimatingQuote ? 0 : 10)
                    .onTapGesture {
                        cycleQuote()
                    }
                
                Button(action: cycleQuote) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                        Text("New inspiration")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(20)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            
            Spacer()
            
            VStack(spacing: 16) {
                Text("Choose your focus duration")
                    .font(.headline)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(durations, id: \.0) { name, duration in
                        FocusDurationButton(
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
                        RoundedRectangle(cornerRadius: 16)
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
        .onAppear {
            // Start with a random quote
            currentQuoteIndex = Int.random(in: 0..<motivationalQuotes.count)
            withAnimation(.easeInOut(duration: 0.8)) {
                isAnimatingQuote = true
            }
            
            // Auto-cycle quotes every 30 seconds
            startQuoteTimer()
        }
        .onChange(of: sessionManager.showingSetupModal) { showing in
            if showing {
                sessionManager.selectedDuration = selectedDuration
            }
        }
    }
    
    private func cycleQuote() {
        withAnimation(.easeOut(duration: 0.3)) {
            isAnimatingQuote = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var newIndex = currentQuoteIndex
            while newIndex == currentQuoteIndex {
                newIndex = Int.random(in: 0..<motivationalQuotes.count)
            }
            currentQuoteIndex = newIndex
            
            withAnimation(.easeIn(duration: 0.5)) {
                isAnimatingQuote = true
            }
        }
    }
    
    private func startQuoteTimer() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            cycleQuote()
        }
    }
}

struct FocusDurationButton: View {
    let name: String
    let duration: TimeInterval
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.blue : Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
                )
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
    @State private var isAnimating = false
    
    private let durations: [(String, TimeInterval)] = [
        ("15 min", 900),
        ("25 min", 1500),
        ("45 min", 2700),
        ("60 min", 3600),
        ("90 min", 5400)
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                
                
                
                // Duration Selection
                VStack(spacing: 16) {
                    Text("Session Duration")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                        ForEach(durations, id: \.0) { name, duration in
                            FocusDurationButton(
                                name: name,
                                duration: duration,
                                isSelected: selectedDuration == duration
                            ) {
                                withAnimation(.spring(response: 0.3)) {
                                    selectedDuration = duration
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                
                Divider()
                    .padding(.vertical, 8)
                
                // Preparation Steps
                VStack(alignment: .leading, spacing: 20) {
                    Text("Preparation Checklist")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    
                    VStack(spacing: 16) {
                        SetupInstructionRow(
                            icon: "iphone.gen2",
                            text: "Place phone face-Up on stable surface",
                            isCompleted: didPlacePhone
                        )
                        
                        SetupInstructionRow(
                            icon: "bell.slash",
                            text: "Movement will trigger gentle reminders",
                            isCompleted: didPlacePhone
                        )
                        
                        SetupInstructionRow(
                            icon: "eye.slash",
                            text: "Avoid distractions during your session",
                            isCompleted: didPlacePhone
                        )
                    }
                    .padding(.horizontal, 4)
                }
                
                Spacer()
                
                // Action Buttons
                VStack(spacing: 12) {
                    
                    // Checklist confirmation
                    Button(action: {
                        withAnimation(.spring(response: 0.4)) {
                            didPlacePhone.toggle()
                        }
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: didPlacePhone ? "checkmark.circle.fill" : "circle")
                            Text(didPlacePhone ? "Phone Confirmed" : "Phone is Face-Up")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(didPlacePhone ? Color.green : Color.blue)
                                .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                        )
                    }
                    
                    // Start Session button (always visible)
                    Button(action: {
                        sessionManager.startSession(duration: selectedDuration)
                        dismiss()
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "play.fill")
                            Text("Start \(Int(selectedDuration/60))-Minute Session")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(didPlacePhone ? Color.green : Color.gray)
                                .shadow(color: .green.opacity(0.3), radius: 8, x: 0, y: 4)
                        )
                    }
                    .disabled(!didPlacePhone)
                    
                    
                    
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

// Checklist Row Component
struct SetupInstructionRow: View {
    let icon: String
    let text: String
    let isCompleted: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(isCompleted ? .green : .blue)
                .frame(width: 24)
            
            Text(text)
                .font(.body)
                .foregroundColor(isCompleted ? .secondary : .primary)
                .strikethrough(isCompleted)
                .multilineTextAlignment(.leading)
            
            Spacer()
            
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 20))
            }
        }
        .padding(.vertical, 8)
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
    @State private var isPulsing = false
    
    var body: some View {
        VStack(spacing: 32) {
            // Header
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                    
                    Text("Focus Session Active")
                        .font(.headline)
                        .foregroundColor(.green)
                }
                
                Text("Please Avoid your Phone and maintain focus")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            
            // Progress Circle
            if let session = sessionManager.currentSession {
                ZStack {
                    // Background circle
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 12)
                        .frame(width: 280, height: 280)
                    
                    // Progress circle
                    Circle()
                        .trim(from: 0, to: session.progress)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [.blue, .purple, .blue]),
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(360)
                            ),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .frame(width: 280, height: 280)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: session.progress)
                    
                    // Time display
                    VStack(spacing: 4) {
                        Text(formatTime(session.remainingTime))
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                        
                        Text("remaining")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        // Progress percentage
                        Text("\(Int(session.progress * 100))% complete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
            
            // Stats
            if let session = sessionManager.currentSession {
                HStack(spacing: 40) {
                    TimerStatView(
                        icon: "clock.fill",
                        label: "Duration",
                        value: "\(Int(session.duration/60)) min",
                        color: .blue
                    )
                    
                    Divider()
                        .frame(height: 40)
                    
                    TimerStatView(
                        icon: "exclamationmark.triangle.fill",
                        label: "Interruptions",
                        value: "\(session.interruptionCount)",
                        color: session.interruptionCount > 0 ? .orange : .green
                    )
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                )
                .padding(.horizontal)
            }
            
            Spacer()
            
          
            
            // End Session Button
            Button(action: {
                sessionManager.beginQuitSession()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                    Text("End Session")
                }
                .font(.body.weight(.medium))
                .foregroundColor(.red)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(Color.red.opacity(0.1))
                )
            }
            .padding(.bottom, 20)
        }
        .padding()
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// Renamed to avoid conflict with existing StatView
struct TimerStatView: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct TipView: View {
    let icon: String
    let text: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.blue)
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 60)
        }
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
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacyDetails = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    // Header
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Welcome to Focus Timer")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Text("Build better focus habits with gentle reminders that help you stay on track.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                    
                    // How It Works
                    FeatureSection(
                        title: "How It Works",
                        accentColor: .blue,
                        items: [
                            FeatureItem(
                                icon: "timer",
                                title: "Set Focus Time",
                                description: "Choose from 15 to 90 minutes of focused work time"
                            ),
                            FeatureItem(
                                icon: "iphone.gen3",
                                title: "Motion Detection",
                                description: "Gentle reminders when you pick up your phone"
                            ),
                            FeatureItem(
                                icon: "speaker.wave.2",
                                title: "Audio Feedback",
                                description: "Spoken reminders keep you on track"
                            ),
                            FeatureItem(
                                icon: "brain.head.profile",
                                title: "Intentional Choices",
                                description: "Thoughtful prompts for intentional breaks"
                            )
                        ]
                    )
                    
                    // Privacy
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .font(.title2)
                                .foregroundColor(.green)
                            
                            Text("Privacy First")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Spacer()
                            
                            Button {
                                withAnimation(.spring()) {
                                    showPrivacyDetails.toggle()
                                }
                            } label: {
                                Image(systemName: showPrivacyDetails ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(8)
                                    .background(Circle().fill(Color(.systemGray6)))
                            }
                        }
                        
                        if showPrivacyDetails {
                            FeatureSection(
                                title: "",
                                accentColor: .green,
                                items: [
                                    FeatureItem(
                                        icon: "location.slash.fill",
                                        title: "No Location Data",
                                        description: "We never access your location"
                                    ),
                                    FeatureItem(
                                        icon: "externaldrive.slash",
                                        title: "Local Processing",
                                        description: "Motion data stays on your device"
                                    ),
                                    FeatureItem(
                                        icon: "moon.zzz.fill",
                                        title: "Active Sessions Only",
                                        description: "No background monitoring"
                                    ),
                                    FeatureItem(
                                        icon: "trash.slash.fill",
                                        title: "No Data Retention",
                                        description: "Session data is deleted immediately"
                                    )
                                ]
                            )
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    // Requirements & Links
                    VStack(alignment: .leading, spacing: 24) {
                        // Requirements
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                Text("Device Requirements")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                RequirementRow(icon: "􀟏", text: "iOS 16.0 or later")
                                RequirementRow(icon: "􀟜", text: "Modern iPhone with accelerometer")
                                RequirementRow(icon: "􀌬", text: "Notifications permission (optional)")
                            }
                        }
                        
                        // Action Buttons
                        VStack(spacing: 12) {
                            Button(action: rateApp) {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                    Text("Rate the App")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "arrow.up.forward")
                                        .font(.caption2)
                                }
                                .foregroundColor(.primary)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.systemGray6))
                                )
                            }
                            
                            Button(action: shareApp) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.caption)
                                    Text("Share with Friends")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "arrow.up.forward")
                                        .font(.caption2)
                                }
                                .foregroundColor(.primary)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.systemGray6))
                                )
                            }
                            
                            Link(destination: URL(string: "https://appgallery.io/Keli")!) {
                                HStack {
                                    Image(systemName: "app.gift")
                                        .font(.caption)
                                    Text("My Other Apps")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "arrow.up.forward")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                                .foregroundColor(.blue)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    
                    // Done Button (at bottom for easier access)
                    Button {
                        sessionManager.completeOnboarding()
                        dismiss()
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.blue)
                            )
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 24)
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Feature Section
struct FeatureSection: View {
    let title: String
    let accentColor: Color
    let items: [FeatureItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .padding(.leading, 4)
            }
            
            VStack(spacing: 16) {
                ForEach(items.indices, id: \.self) { index in
                    FeatureItemView(item: items[index], accentColor: accentColor)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - Feature Item View
struct FeatureItemView: View {
    let item: FeatureItem
    let accentColor: Color
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.1))
                    .frame(width: 44, height: 44)
                
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(item.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
    }
}

// MARK: - Requirement Row
struct RequirementRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}

// MARK: - Feature Item
struct FeatureItem {
    let icon: String
    let title: String
    let description: String
}

// MARK: - Private Functions (keep these as-is)
private func rateApp() {
    let appID = "6751766120"
    let urlString = "https://apps.apple.com/app/id\(appID)?action=write-review"
    
    if let url = URL(string: urlString) {
        UIApplication.shared.open(url)
    }
}

private func shareApp() {
    let appID = "6751766120"
    let url = URL(string: "https://apps.apple.com/app/id\(appID)")!
    
    let activityVC = UIActivityViewController(
        activityItems: [url],
        applicationActivities: nil
    )
    
    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootVC = scene.windows.first?.rootViewController {
        rootVC.present(activityVC, animated: true)
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
