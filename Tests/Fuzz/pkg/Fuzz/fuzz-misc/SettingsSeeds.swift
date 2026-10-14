import Foundation

/// The seeds of the `settings` target.
internal enum SettingsSeeds {
    /// A settings file with a value for every part an import knows.
    internal static let full = """
        {"format":"A File Manager settings","version":1,"settings":{
        "configuration.userCommands":[{"name":"em_show","title":"Show","action":{"command":"echo -n",\
        "parameters":"%P%N %T","startPath":"/tmp"},"symbol":"star"},{"name":"em_b","action":\
        {"command":"cm_wait 5, em_show"}}],
        "configuration.startMenu":[{"title":"One","action":{"command":"ls","parameters":"\\"%S\\""}},{"title":"-"}],
        "configuration.symbols":{"em_show":"star","cm_Exit":"xmark"},
        "keyBindings":{"cm_Exit":["cmd+q","f10","ctrl+opt+shift+cmd+num+"],"em_show":["f5","x"]},
        "left.tabs":{"tabs":[{"location":"file:///tmp/","sortKey":2,"descending":true,"showHidden":false,\
        "title":"T","locked":true},{"location":"mem:///a","sortKey":99,"descending":false,"showHidden":true}],\
        "active":1},
        "right.tabs":{"tabs":[],"active":-5},
        "places.hotlist":{"entries":[{"kind":"item","title":"Home","command":"cd ~","target":"cd /tmp"},\
        {"kind":"submenu","title":"?Sub","children":[{"kind":"separator"},{"title":"x","command":"cm_List 3"}]}],\
        "hideCharacter":"?","hidesMarked":true},
        "places.history.left":{"visits":[{"location":"file:///tmp/","isVisible":true},{"location":"file:///Users/"}]},
        "places.history.frequent":{"counts":{"file:///tmp/":3,"file:///Users/":9}},
        "listingCache.enabled":true,"listingCache.readAhead":false,"extra.key":"plain text"}}
        """

    /// The inputs the target starts from.
    ///
    /// The first passes the checks of an import (every part of it is stored when ticked); the second is
    /// the same file with a value of a kind the checks refuse, which refuses the whole file.
    internal static func all() -> [[UInt8]] {
        seedTexts([
            full,
            full.replacingOccurrences(of: "\"plain text\"", with: "{\"$data\":\"AAEC\"}"),
            "{\"format\":\"A File Manager settings\",\"settings\":{}}",
            "{\"format\":\"A File Manager settings\",\"settings\":{\"configuration.userCommands\":[{\"name\":\"em_x\","
                + "\"action\":{\"command\":\"echo\",\"parameters\":\"?%N:~-0,3 %O.%E %B %C1 %L\"}}]}}"
        ])
    }
}
