# https://github.com/casey/just
default: gen build

gen:
    ./gen.sh

build:
    go build ./...

lint:
    buf lint
    buf breaking --against '.git#tag=$(git describe --tags --abbrev=0)' || true

test: build
