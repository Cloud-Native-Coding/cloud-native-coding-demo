#!/usr/bin/env bash
#
# pod debugging tool for kubernetes clusters with docker runtimes

# Copyright © 2019 Hua Zhihao <ihuazhihao@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

[[ -n $DEBUG ]] && set -x

set -eou pipefail
IFS=$'\n\t'

usage() {
  local SELF
  SELF="kubespy"
  if [[ "$(basename "$0")" == kubectl-* ]]; then
    SELF="kubectl spy"
  fi

  cat <<EOF
kubespy is a pod debugging tool for kubernetes clusters with docker runtimes

Usage:

  $SELF POD [-c CONTAINER] [-n NAMESPACE] [--spy-image SPY_IMAGE]

Examples:

  # debug the first container nginx from mypod
  $SELF mypod

  # debug container nginx from mypod
  $SELF mypod -c nginx

  # debug container nginx from mypod using busybox
  $SELF mypod -c nginx --spy-image busybox

EOF
}

exit_err() {
   echo >&2 "${1}"
   exit 1
}

main() {
  [ $# -eq 0 ] && exit_err "You must specify a pod for spying"

  while [ $# -gt 0 ]; do
      case "$1" in
          -h | --help)
              usage
              exit
              ;;
          -c | --container)
              co="$2"
              shift
              shift
              ;;
          -n | --namespace)
              ns="$2"
              shift
              shift
              ;;
          --spy-image)
              ep="$2"
              shift
              shift
              ;;
          *)
              po="$1"
              shift
              ;;
      esac
  done

  co=${co:-""}
  ns=${ns:-"$(kubectl config view --minify -o 'jsonpath={..namespace}')"}
  ns=${ns:-"default"}

  ep=${ep:-"eu.gcr.io/cloud-native-coding/code-server-java-debug:3.4.1-3"}

  spyid="spy-$(shuf -i 1000-9999 -n 1)"
  kubectl -n "${ns}" delete po/"${spyid}" &>/dev/null || true

  no=$(kubectl -n "${ns}" get pod "${po}" -o "jsonpath={.spec.nodeName}") || exit_err "cannot found Pod ${po}'s nodeName"
  if [[ "${co}" == "" ]]; then
    cid=$(kubectl -n "${ns}" get pod "${po}" -o='jsonpath={.status.containerStatuses[0].containerID}' | sed 's/docker:\/\///')
  else
    cid=$(kubectl -n "${ns}" get pod "${po}" -o='jsonpath={.status.containerStatuses[?(@.name=="'"${co}"'")].containerID}' | sed 's/docker:\/\///')
  fi

  echo "loading spy pod..."
  kubectl -n "${ns}" run --generator=run-pod/v1 --overrides='
  {
    "spec": {
      "hostNetwork": true,
      "hostPID": true,
      "hostIPC": true,
      "nodeName": "'"${no}"'",
      "containers": [
        {
          "name": "spy",
          "image": "busybox",
          "command": [ "/bin/chroot", "/host"],
          "args": [
            "docker",
            "run",
            "--network=container:'"${cid}"'",
            "--pid=container:'"${cid}"'",
            "--ipc=container:'"${cid}"'",
            "'"${ep}"'"
          ],
          "stdin": true,
          "stdinOnce": true,
          "tty": true,
          "volumeMounts": [
            {
              "mountPath": "/host",
              "name": "node"
            }
          ]
        }
      ],
      "volumes": [
        {
          "name": "node",
          "hostPath": {
            "path": "/"
          }
        }
      ]
    }
  }
  ' --image=busybox --restart=Never "${spyid}"

  kubectl -n "${ns}" port-forward pod/"${po}" 8080
  kubectl -n "${ns}" delete po/"${spyid}" --force &>/dev/null || true
}

main "$@"