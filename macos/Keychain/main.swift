import Foundation
import Security

let service = "keyboardless.openai"
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
func fail() -> Never { fputs("無法存取 keyboardless Keychain；請確認登入鑰匙圈已解鎖。\n", stderr); exit(1) }
switch CommandLine.arguments.dropFirst().first {
case "read":
    var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { exit(0) }
    guard status == errSecSuccess, let data = result as? Data else { fail() }
    FileHandle.standardOutput.write(data)
case "write":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count > 0, data.count <= 1024 else { fail() }
    let update = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { fail() }
    } else if status != errSecSuccess { fail() }
case "delete":
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail() }
default: fail()
}
