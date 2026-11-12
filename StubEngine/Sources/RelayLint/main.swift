import Foundation

// RelayLint — enforces the wire layer's path-hostility rules from
// TurboRelay/docs/remote-protocol.md (amendments A1/A2/A3). Reads JSON lines on stdin
// (wire commands and events, in any order), reports every violation to stderr, and exits 1
// when any rule is broken. Used by the conformance harness and, later, as a debug filter
// in front of TurboRelay's bridge tests so loopback's shared filesystem can never mask a
// client-resolved path that would break on the real two-Mac setup.
//
// Rules (wire commands):
//   generate / load: model.path and model.text_encoder_path forbidden — the server
//     resolves paths from the catalog id (A2); model.name and model.family required.
//   generate: params.output forbidden — the server stages results (A2).
//   generate: params.image / params.last_image / params.images[] / params.loras[].path
//     must be {"upload": "<64-hex sha256>"} handles, never path strings (A1).
// Rules (wire events):
//   preview: path forbidden; data (base64) or file_id required (A3).
//   done: path forbidden; file_id required (A2).

func isHex64(_ string: String) -> Bool {
    string.count == 64 && string.allSatisfy { character in
        ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }
}

func isUploadHandle(_ value: Any?) -> Bool {
    guard let object = value as? [String: Any], let upload = object["upload"] as? String else { return false }
    return isHex64(upload)
}

var violations: [String] = []
var checked = 0

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    checked += 1
    let number = checked

    guard let data = trimmed.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        violations.append("line \(number): not a JSON object")
        continue
    }

    if let cmd = object["cmd"] as? String {
        switch cmd {
        case "generate", "load":
            let label = cmd == "generate" ? "generate.model" : "load.model"
            guard let model = object["model"] as? [String: Any] else {
                violations.append("line \(number): \(label) is required")
                continue
            }
            if model["path"] != nil {
                violations.append("line \(number): \(label).path on the wire — the server resolves model paths from the catalog id (A2)")
            }
            if model["text_encoder_path"] != nil {
                violations.append("line \(number): \(label).text_encoder_path on the wire — the server resolves it (A2)")
            }
            if (model["name"] as? String)?.isEmpty != false {
                violations.append("line \(number): \(label).name (the catalog model id) is required (A2)")
            }
            if (model["family"] as? String)?.isEmpty != false {
                violations.append("line \(number): \(label).family is required (A2)")
            }
            if cmd == "generate" {
                guard let params = object["params"] as? [String: Any] else {
                    violations.append("line \(number): generate.params is required")
                    continue
                }
                if params["output"] != nil {
                    violations.append("line \(number): params.output on the wire — the server stages results (A2)")
                }
                for key in ["image", "last_image"] where params[key] != nil && !isUploadHandle(params[key]) {
                    violations.append("line \(number): params.\(key) must be an upload handle {\"upload\": \"<sha256>\"}, not a path (A1)")
                }
                if let images = params["images"] as? [Any] {
                    for (i, image) in images.enumerated() where !isUploadHandle(image) {
                        violations.append("line \(number): params.images[\(i)] must be an upload handle (A1)")
                    }
                }
                if let loras = params["loras"] as? [Any] {
                    for (i, lora) in loras.enumerated() where !isUploadHandle(lora) {
                        violations.append("line \(number): params.loras[\(i)] must be {\"upload\": \"<sha256>\", \"scale\": x} (A1)")
                    }
                }            }
        default:
            break // unload / cancel / shutdown carry no paths
        }
    } else if let event = object["event"] as? String {
        switch event {
        case "preview":
            if object["path"] != nil {
                violations.append("line \(number): preview.path on the wire — previews travel as data or file_id (A3)")
            }
            if object["data"] == nil && object["file_id"] == nil {
                violations.append("line \(number): preview needs data (base64) or file_id (A3)")
            }
        case "done":
            if object["path"] != nil {
                violations.append("line \(number): done.path on the wire — results travel as file_id (A2)")
            }
            if object["file_id"] == nil {
                violations.append("line \(number): done needs file_id (A2)")
            }
        default:
            break
        }
    }
}

for violation in violations { FileHandle.standardError.write(Data((violation + "\n").utf8)) }
FileHandle.standardError.write(Data("\(checked) line(s) checked, \(violations.count) violation(s)\n".utf8))
exit(violations.isEmpty ? 0 : 1)
