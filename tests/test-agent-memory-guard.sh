#!/bin/bash
# Tests for agent-guard/docker-shim: injection, passthrough, minikube exemption (fake REAL docker).
set -u; D="$(cd "$(dirname "$0")/.." && pwd)"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; F=0
sed "s#^REAL=/usr/bin/docker#REAL=$T/fake#" "$D/agent-guard/docker-shim" > "$T/shim"
printf '#!/bin/bash\necho "$*"\n' > "$T/fake"; chmod +x "$T/fake" "$T/shim"
t() { local want="$1"; shift; local got; got=$("$T/shim" "$@"); [ "$got" = "$want" ] && echo "ok   $*" || { echo "FAIL $*: got [$got] want [$want]"; F=1; }; }
t "run --memory=8g --memory-swap=8g --rm img x" run --rm img x
t "container run --memory=8g --memory-swap=8g img"  container run img
t "run --memory=8g --memory-swap=8g img"            run img
t "run -m 2g img"                                   run -m 2g img
t "run --memory=1g --memory-swap=4g img"            run --memory=1g --memory-swap=4g img
t "run --privileged img"                            run --privileged img
t "run --gpus all img"                              run --gpus all img
t "run --name=minikube img"                         run --name=minikube img
t "ps -a"                                           ps -a
t "-H unix:///x run img"                            -H unix:///x run img
AGENT_DOCKER_MEM=16g t "run --memory=16g --memory-swap=16g img" run img
AGENT_DOCKER_NO_LIMIT=1 t "run img" run img
[ $F = 0 ] && echo ALL PASS || { echo FAILURES; exit 1; }
