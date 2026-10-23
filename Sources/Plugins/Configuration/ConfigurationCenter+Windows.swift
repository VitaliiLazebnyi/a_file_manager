import AFMKernel
import AppKit

/// The center's windows: the command browser, the options, the text windows and the help texts. Main thread only.
extension ConfigurationCenter {
    /// Lets the user pick a command for an editor (the magnifier button of spec 14).
    internal func pickCommand() -> CommandRow? {
        browser().pick()
    }

    /// The *Choose command* dialog, made on first use and kept for the next one.
    internal func browser() -> CommandBrowserController {
        if let browserWindow {
            return browserWindow
        }
        let controller = CommandBrowserController(center: self)
        browserWindow = controller
        return controller
    }

    /// Opens the options window (made on first use) on the given page.
    internal func showOptions(_ section: OptionsWindowController.Section) {
        let controller = optionsWindow ?? OptionsWindowController(center: self)
        optionsWindow = controller
        controller.show(section)
    }

    /// Shows a text in a window of its own; a window with the same title is reused.
    internal func showText(_ text: String, title: String) {
        let controller = textWindows[title] ?? TextWindowController(title: title)
        textWindows[title] = controller
        controller.show(text, present: effects.present)
    }

    /// Closes every window the center opened (when the plugin stops).
    internal func closeWindows() {
        optionsWindow?.close()
        browserWindow?.close()
        for window in textWindows.values {
            window.close()
        }
    }

    /// The keyboard help, from the bindings in force (spec 17 › Help, `cm_Keyboard`).
    internal func keyboardHelp() -> String {
        "Keyboard shortcuts of \(kernel.productName)\nChange them in Configuration › Options › Keyboard.\n\n"
            + CommandCatalog.shortcutSheet(commandRows(), menus: kernel.menus.menus)
    }

    /// Where the things a Total Commander user looks for are in this program.
    internal func whatIsWhere() -> String {
        """
        \(kernel.productName): what is where

        Options            Configuration › Options (⌘,). The pages come from the program's
                           parts; changes apply with Apply or OK.
        Keys               Options › Keyboard: select a command, press Set Shortcut and
                           then the key. A key that is in use names its command first.
                           Help › Keyboard Shortcuts lists the keys in force.
        Button bar         Options › Button Bar: add commands and separators, reorder,
                           choose a symbol, or go back to the default bar.
        User commands      Configuration › User Commands: commands of your own (em_name)
                           that run a program, a shell line, cd <folder> or other
                           commands, with parameters such as %P %N %S %L. They can be
                           given keys, put on the button bar and typed on the command line.
        Start menu         Options › Start Menu. The n-th entry is also cm_UserMenu<n>.
        All commands       Configuration › Choose Command lists every command with its
                           name and keys, and runs the one you choose.
        Settings           They are kept in the macOS preferences and stored the moment
                           they change; there is no wincmd.ini. Options › Settings File
                           exports them to a file, imports them and resets them.
        Language           The program is in English. Total Commander's language files
                           (.LNG, .MNU) are Windows resources and are not read.
        Not on the Mac     Run as administrator (*), 8.3 short names (the lower-case
                           parameter codes insert the long names), icon libraries
                           (buttons use system symbols), submenus in the Start menu.
        """
    }
}
