import Foundation

enum IOSRuntimeEvents {
    static func log(instance: String, operation: String, line: String) -> [String: Any] {
        ["instanceId": instance, "operationId": operation, "line": line,
         "message": line, "level": "info"]
    }

    static func mode(_ event: [String: Any], current: [String: Any], remoteActive: Bool) -> [String: Any]? {
        guard !remoteActive, ["state", "instanceId", "operationId"].allSatisfy({
            event[$0] as? String == current[$0] as? String
        }), event["serverReady"] as? Bool == current["serverReady"] as? Bool else { return nil }
        if event["serverReady"] as? Bool != true {
            guard current["instanceId"] == nil, current["operationId"] == nil,
                  let state = current["state"] as? String, ["stopped", "failed"].contains(state) else { return nil }
        }
        var value = event
        value["runtimeMode"] = event["mode"]
        value["mode"] = "launcher"
        value["tavernRunning"] = event["serverReady"] as? Bool == true
        return value
    }
}
