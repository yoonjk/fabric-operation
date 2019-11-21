#!/bin/bash
# Copyright © 2018. TIBCO Software Inc.
#
# This file is subject to the license terms contained
# in the license file that is distributed with this file.

# Run this script in cli docker container to create channel and test a sample chaincode
# usage: network-util.sh test

function test {
  createChannel ${TEST_CHANNEL}
  if [ "$?" -ne 0 ]; then
    return 1
  fi
  joinChannel "peer-0" ${TEST_CHANNEL} "anchor"
  if [ "$?" -ne 0 ]; then
    return 1
  fi

  installChaincode "peer-0" "chaincode_example02/go" "mycc" "1.0" "new"
  instantiateChaincode "peer-0" ${TEST_CHANNEL} "mycc" "1.0" '{"Args":["init","a","100","b","200"]}'

  echo "Wait 10s before testing chaincode ..."
  sleep 10
  queryChaincode "peer-0" ${TEST_CHANNEL} "mycc" '{"Args":["query","a"]}'
  invokeChaincode "peer-0" ${TEST_CHANNEL} "mycc" '{"Args":["invoke","a","b","10"]}'

  echo "wait 5s for transaction to commit ..."
  sleep 5
  echo "Following query should return 90"
  queryChaincode "peer-0" ${TEST_CHANNEL} "mycc" '{"Args":["query","a"]}'
}

# createChannel <channel>
function createChannel {
  echo "check if channel ${1} exists"
  peer channel fetch oldest ${1}.pb -c ${1} -o ${ORDERER_URL} --tls --cafile $ORDERER_CA
  if [ "$?" -ne 0 ]; then
    echo "create channel ${1} ..."
    if [ -f "${1}.tx" ]; then
      peer channel create -c ${1} -f ${1}.tx --outputBlock ${1}.pb -o ${ORDERER_URL} --tls --cafile $ORDERER_CA
    else
      echo "Error: cannot find file ${1}.tx. must create it using msp-util.sh first."
      return 1
    fi
  else
    echo "channel ${1} already exists"
  fi
}

# joinChannel <peer> <channel> [anchor]
function joinChannel {
  echo "check if channel ${2} exists, must get genesis block to join channel"
  peer channel fetch oldest ${2}.pb -c ${2} -o ${ORDERER_URL} --tls --cafile $ORDERER_CA
  if [ "$?" -ne 0 ]; then
    echo "Error: channel ${2} does not exist, must create it first"
    return 1
  fi
  local _env="CORE_PEER_ADDRESS=${1}.${FABRIC_ORG}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  if [ ! -z "${SVC_DOMAIN}" ]; then
    _env="CORE_PEER_ADDRESS=${1}.peer.${SVC_DOMAIN}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  fi
  echo "check if ${1} joined channel ${2}"
  eval "${_env} peer channel getinfo -c ${2}"
  if [ "$?" -ne 0 ]; then
    echo "${1} join channel ${2} ..."
    eval "${_env} peer channel join -b ${2}.pb"
  else
    echo "peer ${1} already joined channel ${2}"
  fi
  if [ "${3}" == "anchor" ]; then
    echo "update anchor peer for channel ${2} ..."
    eval "${_env} peer channel update -o ${ORDERER_URL} -c ${2} -f ${2}-anchors.tx --tls --cafile $ORDERER_CA"
  fi
}

# installChaincode <peer> <src> <name> [<version>] [new] [<lang>]
function installChaincode {
  local _ccpath=${GOPATH}/src/github.com/chaincode/${2}
  local _env="CORE_PEER_ADDRESS=${1}.${FABRIC_ORG}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  if [ ! -z "${SVC_DOMAIN}" ]; then
    _env="CORE_PEER_ADDRESS=${1}.peer.${SVC_DOMAIN}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
    # copy cc src required once for Kubernetes only
    if [ -d "${_ccpath}" ]; then
      if [ "${5}" == "new" ]; then
        echo "replace old code in ${_ccpath}"
        rm -R ${_ccpath}/*
        cp -R ./chaincode/${2}/* ${_ccpath}
      fi
    else
      echo "copy new chaincode to folder ${_ccpath}"
      mkdir -p ${_ccpath}
      cp -R ./chaincode/${2}/* ${_ccpath}
    fi
  fi

  local _version=${4:-"1.0"}
  local _lang=${6:-"golang"}
  echo "check if chaincode ${3}:${_version} has been installed"
  eval "${_env} peer chaincode list --installed" | grep "Name: ${3}, Version: ${_version}"
  if [ "$?" -ne 0 ]; then
    echo "Install chaincode ${3}:${_version} from github.com/chaincode/${2} ..."
    eval "${_env} peer chaincode install -n ${3} -v ${_version} -l ${_lang} -p \"github.com/chaincode/${2}\""
  else
    echo "chaincode ${3}:${_version} already installed"
  fi
}

# instantiateChaincode <peer> <channel> <name> [<version>] [args] [policy] [lang]
function instantiateChaincode {
  local _env="CORE_PEER_ADDRESS=${1}.${FABRIC_ORG}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  if [ ! -z "${SVC_DOMAIN}" ]; then
    _env="CORE_PEER_ADDRESS=${1}.peer.${SVC_DOMAIN}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  fi
  local _version=${4:-"1.0"}
  local _policy=${6:-"OR ('${ORG}MSP.peer')"}
  local _lang=${7:-"golang"}
  local _args=${5:-'{"Args":["init"]}'}

  echo "check if chaincode ${3}:${_version} has been instantiated"
  eval "${_env} peer chaincode list -C ${2} --instantiated" | grep "Name: ${3}, Version: ${_version}"
  if [ "$?" -ne 0 ]; then
    echo "instantiate chaincode ${3}:${_version} (${_lang}) on peer ${1}, channel ${2}, args ${_args} ..."
    eval "${_env} peer chaincode instantiate -C ${2} -n ${3} -v ${_version} -l ${_lang} -c '${_args}' -P \"${_policy}\" -o ${ORDERER_URL} --tls --cafile ${ORDERER_CA}"
  else
    echo "chaincode ${3}:${_version} already instantiated"
  fi
}

# upgrade Chaincode <peer> <channel> <name> <version> [args] [policy] [lang]
function upgradeChaincode {
  local _env="CORE_PEER_ADDRESS=${1}.${FABRIC_ORG}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  if [ ! -z "${SVC_DOMAIN}" ]; then
    _env="CORE_PEER_ADDRESS=${1}.peer.${SVC_DOMAIN}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  fi
  local _policy=${6:-"OR ('${ORG}MSP.peer')"}
  local _lang=${7:-"golang"}
  local _args=${5:-'{"Args":["init"]}'}

  echo "upgrade chaincode ${3}:${4} (${_lang}) on peer ${1}, channel ${2}, args ${_args} ..."
  eval "${_env} peer chaincode upgrade -C ${2} -n ${3} -v ${4} -l ${_lang} -c '${_args}' -P \"${_policy}\" -o ${ORDERER_URL} --tls --cafile ${ORDERER_CA}"
}

# queryChaincode <peer> <channel> <name> <args>
function queryChaincode {
  local _env="CORE_PEER_ADDRESS=${1}.${FABRIC_ORG}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  if [ ! -z "${SVC_DOMAIN}" ]; then
    _env="CORE_PEER_ADDRESS=${1}.peer.${SVC_DOMAIN}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  fi
  local _args=''${4}''
  eval "${_env} peer chaincode query -C ${2} -n ${3} -c '${_args}'"
}

# invokeChaincode <peer> <channel> <name> <args>
function invokeChaincode {
  local _env="CORE_PEER_ADDRESS=${1}.${FABRIC_ORG}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  if [ ! -z "${SVC_DOMAIN}" ]; then
    _env="CORE_PEER_ADDRESS=${1}.peer.${SVC_DOMAIN}:7051 CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/crypto/${1}/tls/ca.crt"
  fi
  local _args=''${4}''
  eval "${_env} peer chaincode invoke -C ${2} -n ${3} -c '${_args}' -o ${ORDERER_URL} --tls --cafile $ORDERER_CA"
}

# create channel update tx for adding a new org to a channel
# assuming config file <msp>.json is already in the CLI working directory
# output transaction file is written in working drectory as <channel>-<msp>.pb
# addOrg <msp>, <channel>
function addOrg {
  # fetch channel config
  peer channel fetch config ${2}-config.pb -c ${2} -o ${ORDERER_URL} --tls --cafile ${ORDERER_CA}
  configtxlator proto_decode --input ${2}-config.pb --type common.Block | jq .data.data[0].payload.data.config > ${2}-config.json
  # insert new msp into application.groups
  if [ -f "${1}.json" ]; then
    jq -s '.[0] * {"channel_group":{"groups":{"Application":{"groups": {"'${1}'":.[1]}}}}}' ${2}-config.json ${1}.json > ${2}-modified.json
  else
    echo "cannot find MSP config - ${1}.json. create it using msp-util.sh before continue"
    return 1
  fi

  # calculate pb diff
  configtxlator proto_encode --input ${2}-config.json --type common.Config --output ${2}-config.pb
  configtxlator proto_encode --input ${2}-modified.json --type common.Config --output ${2}-modified.pb
  configtxlator compute_update --channel_id ${2} --original ${2}-config.pb --updated ${2}-modified.pb --output ${2}-update.pb
  local dif=$(wc -c "${2}-update.pb" | awk '{print $1}')
  if [ "${dif}" -eq 0 ]; then
    echo "${1} had already been added to ${2}. no update is required"
    return 1
  fi

  # construct update with re-attached envelope
  configtxlator proto_decode --input ${2}-update.pb --type common.ConfigUpdate | jq . > ${2}-update.json
  echo '{"payload":{"header":{"channel_header":{"channel_id":"'${2}'", "type":2}},"data":{"config_update":'$(cat ${2}-update.json)'}}}' | jq . > ${2}-${1}.json
  configtxlator proto_encode --input ${2}-${1}.json --type common.Envelope --output ${2}-${1}.pb
  echo "created channel update file ${2}-${1}.pb"
}

# Print the usage message
function printUsage {
  echo "Usage: "
  echo "  network-util.sh <cmd> <args>"
  echo "    <cmd> - one of the following commands:"
  echo "      - 'test' (default) - smoke test using a test channel and chaincode"
  echo "      - 'create-channel' - create a channel using peer-0, <args> = <channel>"
  echo "      - 'join-channel' - join a peer to a channel, <args> = <peer> <channel> [anchor]"
  echo "        e.g., network-util.sh join-channel \"peer-0\" \"mychannel\" anchor"
  echo "      - 'install-chaincode' - install chaincode on a peer, <args> = <peer> <src> <name> [<version>] [new]"
  echo "        e.g., network-util.sh install-chaincode \"peer-0\" \"chaincode_example02/go\" \"mycc\" \"1.0\" new"
  echo "      - 'instantiate-chaincode' - instantiate chaincode on a peer, <args> = <peer> <channel> <name> [<version>] [<args>] [<policy>] [<lang>]"
  echo "        e.g., network-util.sh instantiate-chaincode \"peer-0\" \"mychannel\" \"mycc\" \"1.0\" '{\"Args\":[\"init\",\"a\",\"100\",\"b\",\"200\"]}'"
  echo "      - 'upgrade-chaincode' - upgrade chaincode on a peer, <args> = <peer> <channel> <name> <version> [<args>] [<policy>] [<lang>]"
  echo "        e.g., network-util.sh upgrade-chaincode \"peer-0\" \"mychannel\" \"mycc\" \"2.0\" '{\"Args\":[\"init\",\"a\",\"100\",\"b\",\"200\"]}'"
  echo "      - 'query-chaincode' - query chaincode from a peer, <args> = <peer> <channel> <name> <args>"
  echo "        e.g., network-util.sh query-chaincode \"peer-0\" \"mychannel\" \"mycc\" '{\"Args\":[\"query\",\"a\"]}'"
  echo "      - 'invoke-chaincode' - invoke chaincode from a peer, <args> = <peer> <channel> <name> <args>"
  echo "        e.g., network-util.sh invoke-chaincode \"peer-0\" \"mychannel\" \"mycc\" '{\"Args\":[\"invoke\",\"a\",\"b\",\"10\"]}'"
  echo "      - 'add-org-tx' - generate update tx for add new msp to a channel, <args> = <msp> <channel>"
  echo "      - 'sign-transaction' - sign a config update transaction file in the CLI working directory, <args> = <tx-file>"
  echo "        e.g., network-util.sh sign-transaction \"mychannel-peerorg1MSP.pb\""
  echo "      - 'update-channel' - send transaction to update a channel, <args> = <tx-file> <channel>"
  echo "        e.g., network-util.sh update-channel \"mychannel-peerorg1MSP.pb\" mychannel"
}

CMD=${1:-"test"}
shift
ARGS="$@"

case "${CMD}" in
test)
  echo "network smoke test"
  test
  ;;
create-channel)
  echo "create channel [ ${ARGS} ]"
  createChannel ${ARGS}
  ;;
join-channel)
  echo "join channel [ ${ARGS} ]"
  joinChannel ${ARGS}
  ;;
install-chaincode)
  echo "install chaincode [ ${ARGS} ]"
  installChaincode ${ARGS}
  ;;
instantiate-chaincode)
  echo "instantiate chaincode [ ${ARGS} ]"
  instantiateChaincode ${1} ${2} ${3} "${4}" ''${5}'' "${6}" ${7}
  ;;
upgrade-chaincode)
  echo "upgrade chaincode [ ${ARGS} ]"
  upgradeChaincode ${1} ${2} ${3} "${4}" ''${5}'' "${6}" ${7}
  ;;
query-chaincode)
  echo "query chaincode [ ${ARGS} ]"
  queryChaincode ${1} ${2} ${3} ''${4}''
  ;;
invoke-chaincode)
  echo "invoke chaincode [ ${ARGS} ]"
  invokeChaincode ${1} ${2} ${3} ''${4}''
  ;;
add-org-tx)
  echo "generate update tx for add new msp to a channel [ ${ARGS} ]"
  addOrg ${ARGS}
  ;;
update-channel)
  if [ ! -f "${1}" ]; then
    echo "cannot find the transaction file ${1}"
    exit 1
  fi
  echo "send transaction ${1} to update channel ${2}"
  peer channel update -f ${1} -c ${2} -o ${ORDERER_URL} --tls --cafile ${ORDERER_CA}
  ;;
sign-transaction)
  if [ ! -f "${1}" ]; then
    echo "cannot find the transaction file ${1}"
    exit 1
  fi
  echo "sign transaction ${1}"
  peer channel signconfigtx -f ${1}
  ;;
*)
  printUsage
  exit 1
esac