import SwiftUI
import AutoVolumeShared

struct VolumeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: AppViewModel

    @State private var name = ""
    @State private var protocolType = VolumeProtocol.smb
    @State private var server = ""
    @State private var remotePath = ""
    @State private var username = ""
    @State private var password = ""
    @State private var mountPoint = "/Volumes/"
    @State private var intervalMinutes = 5.0

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Protocol", selection: $protocolType) {
                ForEach(VolumeProtocol.allCases) { item in
                    Text(item.rawValue.uppercased()).tag(item)
                }
            }
            TextField("Server", text: $server)
            TextField("Remote Path", text: $remotePath)
            TextField("Username", text: $username)
            SecureField("Password", text: $password)
            TextField("Mount Point", text: $mountPoint)
            Slider(value: $intervalMinutes, in: 1...60, step: 1) {
                Text("Check Interval")
            }
            Text("Every \(Int(intervalMinutes)) minutes")

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    let config = VolumeConfig(
                        name: name,
                        protocolType: protocolType,
                        server: server,
                        remotePath: remotePath,
                        username: username.isEmpty ? nil : username,
                        mountPoint: mountPoint,
                        checkIntervalSeconds: intervalMinutes * 60,
                        isEnabled: true
                    )
                    try? viewModel.add(config, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
