import AppKit
import LapangkeCore
import SwiftUI
@preconcurrency import UserNotifications

/// Panduan izin pertama kali: status diperiksa langsung, jadi kartu berubah centang begitu izin diberikan.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var fullDiskAccess = DiskInspector.hasFullDiskAccess()
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var islandOn = AppServices.shared.islandEnabled
    @State private var launchAtLogin = false
    private let services = AppServices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BrandMark(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selamat datang di Lapangke").font(.system(size: 26, weight: .bold)).tracking(-0.6).foregroundStyle(Brand.ink)
                    Text("Tiga langkah supaya Lapangke bisa membaca semua data dan mengabari Anda tepat waktu.")
                        .font(.callout).foregroundStyle(Brand.ink2)
                }
            }

            StepCard(number: 1, title: "Akses penuh ke disk", done: fullDiskAccess, wash: Brand.peach) {
                HStack(alignment: .top, spacing: 16) {
                    DraggableAppTile()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tanpa izin ini, Tong Sampah, Containers, dan media chat tidak terlihat. Seret ikon di samping ke daftar Full Disk Access, lalu nyalakan.")
                            .font(.callout).foregroundStyle(Brand.ink2).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Buka Full Disk Access") { model.openFullDiskAccessSettings() }
                                .buttonStyle(PillButtonStyle(background: Brand.ink))
                            if !fullDiskAccess {
                                Button("Buka ulang Lapangke") { Self.relaunch() }
                                    .help("macOS baru memberi akses setelah app dibuka ulang")
                            }
                        }
                    }
                }
            }

            StepCard(number: 2, title: "Notifikasi pintar", done: notificationStatus == .authorized || notificationStatus == .provisional, wash: Brand.sky) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kabar hanya saat penting: ruang menipis, ruang turun drastis (lengkap dengan penyebabnya), SSD dicolok, dan pembersihan selesai. Tiap kabar punya tombol aksi.")
                        .font(.callout).foregroundStyle(Brand.ink2).fixedSize(horizontal: false, vertical: true)
                    if notificationStatus == .denied {
                        Button("Buka pengaturan Notifikasi") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    } else if notificationStatus == .notDetermined {
                        Button("Izinkan notifikasi") {
                            Task {
                                await services.notifications.requestAuthorization()
                                notificationStatus = services.notifications.status
                            }
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            }

            StepCard(number: 3, title: "Pulau Lapangke & menu bar", done: islandOn, wash: Brand.lime) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kapsul kecil di tengah atas layar yang muncul hanya saat ada yang penting, dengan progres pembersihan live dan peringatan yang bisa langsung ditindak.")
                            .font(.callout).foregroundStyle(Brand.ink2).fixedSize(horizontal: false, vertical: true)
                        Toggle("Tampilkan Pulau Lapangke", isOn: $islandOn)
                        Toggle("Buka Lapangke saat login (selalu siaga di menu bar)", isOn: $launchAtLogin)
                    }
                    Button { services.peek() } label: { Label("Coba sekarang", systemImage: "capsule.fill") }
                        .buttonStyle(PillButtonStyle(background: Brand.ink))
                        .disabled(!islandOn)
                }
            }

            HStack {
                Button("Nanti saja") { finish() }
                Spacer()
                Button(fullDiskAccess ? "Mulai pindai" : "Lanjut tanpa akses penuh") {
                    finish()
                    Task { await model.scan() }
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onChange(of: islandOn) { _, value in services.islandEnabled = value }
        .onChange(of: launchAtLogin) { _, value in if model.launchAtLogin != value { model.launchAtLogin = value } }
        .task {
            launchAtLogin = model.launchAtLogin
            // Periksa izin terus selama panduan terbuka.
            while !Task.isCancelled {
                let granted = await Task.detached { DiskInspector.hasFullDiskAccess() }.value
                if granted != fullDiskAccess { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { fullDiskAccess = granted } }
                await services.notifications.refreshStatus()
                if services.notifications.status != notificationStatus {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { notificationStatus = services.notifications.status }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        model.showOnboarding = false
    }

    /// macOS menerapkan Full Disk Access ke proses baru, jadi app dibuka ulang.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let wash: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if done {
                    Sticker(symbol: "checkmark", background: Brand.ok, size: 38).transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)").font(.headline).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Brand.accent, in: UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 4, bottomTrailingRadius: 13, topTrailingRadius: 13))
                        .rotationEffect(.degrees(-10))
                }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(Brand.ink)
                    if done { Text("Siap").font(.caption.weight(.bold)).foregroundStyle(Brand.ok) }
                }
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash, in: ExpressiveShape(radius: 22, small: 6))
    }
}

/// Ikon app yang bisa diseret langsung ke daftar Full Disk Access di System Settings.
struct DraggableAppTile: View {
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 58, height: 58)
                .shadow(color: Brand.ink.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 10 : 4, y: 3)
                .scaleEffect(hovering ? 1.06 : 1)
            Text("Seret ke daftar").font(.caption2.weight(.semibold)).foregroundStyle(Brand.accent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
        .help("Seret ikon ini ke daftar Full Disk Access")
    }
}
