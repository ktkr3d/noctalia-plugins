# Ollama Remote

## Server

1. install ollama apps
2. add models
3. add environment variable
	name: OLLAMA_HOST
	value: 0.0.0.0:11434
4 . start ollama apps

## Client

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
