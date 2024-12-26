# vaxis-launcher

vaxis-launcher is a TUI launcher based on [pop-launcher](https://github.com/pop-os/launcher)

![vaxis-launcher](./screenshot.png)

## Usage

First, you must have `pop-launcher` installed.

Second, use your favorite terminal to run `vaxis-launcher`. Personally, I have a
keybind to launch a terminal running this command. I use a rule within Sway to
launch a floating terminal running `vaxis-launcher`. Maybe you should too?

## Configuration

Configuration is done by modifying a couple lines in the source files and
rebuilding the project.

`launch_cmd` - this is the command to launch an application. For sway, this
should be `swaymsg exec`

`terminal_cmd` - for Desktop Entries which require a terminal, this is the
terminal cmd to use. This will be appended to `launch_cmd`. For example, to
launch a command with foot you would set this to `foot -e`

## Installation

`vaxis-launcher` can be installed with zig. Currently, it uses
`0.14.0-dev.2456+a68119f8f`. Installation should be something like `zig build
-Doptimize=ReleaseSafe --prefix $HOME/.local`

## Contributing

Contributions are welcome.

## Roadmap

- Icons via kitty graphics protocol
- Tab completion
- Real configuration
