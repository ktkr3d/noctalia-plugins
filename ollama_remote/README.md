# Ollama Remote Chat

Chat using the Ollama API on a remote PC

## Plugin

| Field | Value |
| --- | --- |
| ID | `ktkr3d/ollama_remote` |
| Entries | Bar widget: `status`; panel: `chat` |

## Requirements

Install `ollama`.

## Usage

Add the widget to your bar.
Open the panel and connect your ollama server by URL.
Select model.
Send messages.

To toggle or open the panel from a terminal or keybinding:

```sh
noctalia msg panel-toggle ktkr3d/ollama_remote:chat
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_label` | `bool` | `false` | Show plugin name. |

## Notes

## Server settings

```cmd
winget install -e --id Ollama.Ollama
```
search model name from `https://ollama.com/library`
```cmd
ollama pull <model name>
```
```cmd
set OLLAMA_HOST=0.0.0.0
ollama serve
```

## Client settingss

```sh
sudo pacman -S ollama
```
```sh
noctalia msg plugins source add ktkr3d git https://github.com/ktkr3d/noctalia-plugins
```
```sh
noctalia msg plugins enable ktkr3d/ollama_remote
```
```sh
noctalia msg panel-toggle ktkr3d/ollama_remote:chat
```
