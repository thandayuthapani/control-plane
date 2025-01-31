#!/usr/bin/env bash
ROOT_PATH=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

source ${ROOT_PATH}/kyma-scripts/testing-common.sh

readonly TMP_DIR=$(mktemp -d)

echo "ARTIFACTS: ${ARTIFACTS}"
readonly JUNIT_REPORT_PATH="${ARTIFACTS:-${TMP_DIR}}/junit_kcp_octopus-test-suite.xml"

suiteName="testsuite-all"
echo "----------------------------"
echo "- Testing Control Plane..."
echo "----------------------------"

kc="kubectl $(context_arg)"

# due to change between version
# 1.17: https://github.com/kyma-project/kyma/blob/release-1.17/tests/integration/logging/pkg/logstream/logstream.go#L75
# and 1.18: https://github.com/kyma-project/kyma/blob/release-1.18/tests/integration/logging/pkg/logstream/logstream.go#L75,
# logging test will never succeed. Pod with URL to local domain (kyma.local) will not achieve destination endpoint.
${kc} delete testdefinitions.testing.kyma-project.io -n kyma-system logging

${kc} get clustertestsuites.testing.kyma-project.io > /dev/null 2>&1
if [[ $? -eq 1 ]]
then
   echo "ERROR: script requires ClusterTestSuite CRD"
   exit 1
fi

# match all tests besides compass one

cat <<EOF | ${kc} apply -f -
apiVersion: testing.kyma-project.io/v1alpha1
kind: ClusterTestSuite
metadata:
  labels:
    controller-tools.k8s.io: "1.0"
  name: ${suiteName}
spec:
  maxRetries: 1
  concurrency: 1
  selectors:
    matchLabelExpressions:
      - "release != compass"
EOF

startTime=$(date +%s)

testExitCode=0
previousPrintTime=-1

while true
do
    currTime=$(date +%s)
    statusSucceeded=$(${kc} get cts ${suiteName}  -ojsonpath="{.status.conditions[?(@.type=='Succeeded')]}")
    statusFailed=$(${kc} get cts ${suiteName}  -ojsonpath="{.status.conditions[?(@.type=='Failed')]}")
    statusError=$(${kc} get cts  ${suiteName} -ojsonpath="{.status.conditions[?(@.type=='Error')]}" )

    if [[ "${statusSucceeded}" == *"True"* ]]; then
       echo "Test suite '${suiteName}' succeeded."
       break
    fi

    if [[ "${statusFailed}" == *"True"* ]]; then
        echo "Test suite '${suiteName}' failed."
        testExitCode=1
        break
    fi

    if [[ "${statusError}" == *"True"* ]]; then
        echo "Test suite '${suiteName}' errored."
        testExitCode=1
        break
    fi

    sec=$((currTime-startTime))
    min=$((sec/60))
    if (( min > 60 )); then
        echo "Timeout for test suite '${suiteName}' occurred."
        testExitCode=1
        break
    fi
    if (( ${previousPrintTime} != ${min} )); then
        echo "ClusterTestSuite not finished. Waiting..."
        previousPrintTime=${min}
    fi
    sleep 3
done

echo "Test summary"
kubectl get cts  ${suiteName} -o=go-template --template='{{range .status.results}}{{printf "Test status: %s - %s" .name .status }}{{ if gt (len .executions) 1 }}{{ print " (Retried)" }}{{end}}{{print "\n"}}{{end}}'

waitForTerminationAndPrintLogs ${suiteName}
cleanupExitCode=$?

echo "ClusterTestSuite details:"
kubectl get cts ${suiteName} -oyaml

echo "Generate JUnit test summary (${JUNIT_REPORT_PATH})"
kyma test status "${suiteName}" -ojunit | sed 's/ (executions: [0-9]*)"/"/g' > "${JUNIT_REPORT_PATH}"


kubectl delete cts ${suiteName}

printImagesWithLatestTag
latestTagExitCode=$?

exit $((${testExitCode} + ${cleanupExitCode} + ${latestTagExitCode}))
