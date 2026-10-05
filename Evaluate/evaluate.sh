#!/bin/bash

evaluate_project() {

    local student_id="$1"
    local projectName="gpu-dra-lab"
    local LOG_PATH="/home/ubuntu"

    cd "/home/ubuntu/$projectName" 2>/dev/null || true

    total_passed=0
    total_failed=0
    final_score=0


    # ============================================================
    # Common Configuration
    # ============================================================

    # Kubernetes resources are discovered dynamically.
    #
    # The following student resource names are NOT fixed:
    #
    #   - Namespace
    #   - DRA driver DaemonSet name
    #   - DRA driver container name
    #   - DRA driver name
    #   - DeviceClass name
    #   - ResourceClaim names
    #   - Pod names
    #   - ResourceQuota name
    #
    # The lab uses the official Kubernetes DRA example driver
    # implementation. Therefore the evaluator identifies the
    # driver implementation using its container image, while
    # allowing Kubernetes object names to be completely dynamic.

    # Expected minimum final capacity for TC07.
    MIN_FINAL_DEVICES="${MIN_FINAL_DEVICES:-4}"

    # Expected minimum final running GPU workloads for TC07.
    MIN_FINAL_WORKLOADS="${MIN_FINAL_WORKLOADS:-4}"


    # ============================================================
    # Helper Functions
    # ============================================================


    # ------------------------------------------------------------
    # Get all ResourceSlice JSON
    # ------------------------------------------------------------
    get_resourceslices_json() {

        kubectl get resourceslices \
            -o json 2>/dev/null
    }


    # ------------------------------------------------------------
    # Discover DRA driver dynamically from ResourceSlice
    #
    # No fixed driver name is used.
    # ------------------------------------------------------------
    find_dra_driver() {

        local driver_name=""

        driver_name=$(kubectl get resourceslices \
            -o json 2>/dev/null | \
            python3 -c '
import json
import sys

try:

    data = json.load(sys.stdin)

    for item in data.get("items", []):

        driver = item.get(
            "spec", {}
        ).get(
            "driver", ""
        )

        if driver:

            print(driver)
            sys.exit(0)

except Exception:
    pass
' 2>/dev/null)

        if [ -n "$driver_name" ]; then
            echo "$driver_name"
        fi
    }


    # ------------------------------------------------------------
    # Find running DRA driver DaemonSet dynamically
    #
    # DaemonSet name and namespace are NOT fixed.
    #
    # The official Kubernetes DRA example driver is identified
    # through its container image, not through its DaemonSet name.
    # ------------------------------------------------------------
    find_dra_daemonset() {

        kubectl get daemonsets -A \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

try:

    data = json.load(sys.stdin)

    candidates = []

    for item in data.get("items", []):

        metadata = item.get(
            "metadata", {}
        )

        spec = item.get(
            "spec", {}
        )

        status = item.get(
            "status", {}
        )

        name = metadata.get(
            "name", ""
        )

        namespace = metadata.get(
            "namespace", ""
        )

        desired = status.get(
            "desiredNumberScheduled",
            0
        ) or 0

        ready = status.get(
            "numberReady",
            0
        ) or 0

        containers = spec.get(
            "template", {}
        ).get(
            "spec", {}
        ).get(
            "containers", []
        )

        driver_image_found = False

        for container in containers:

            image = container.get(
                "image",
                ""
            ).lower()

            # Official Kubernetes DRA example driver.
            #
            # This checks the implementation image,
            # NOT the DaemonSet name.
            if "dra-example-driver" in image:

                driver_image_found = True
                break


        if driver_image_found:

            candidates.append(
                (
                    namespace,
                    name,
                    desired,
                    ready
                )
            )


    # Prefer a ready DaemonSet.
    candidates.sort(
        key=lambda x: (
            x[3] > 0,
            x[2] > 0
        ),
        reverse=True
    )


    if candidates:

        namespace, name, desired, ready = candidates[0]

        print(
            namespace + "|" +
            name + "|" +
            str(desired) + "|" +
            str(ready)
        )

except Exception:
    pass
'
    }


    # ------------------------------------------------------------
    # Count ResourceSlices belonging to discovered driver
    # ------------------------------------------------------------
    count_driver_resourceslices() {

        local driver="$1"

        if [ -z "$driver" ]; then
            echo "0"
            return
        fi

        kubectl get resourceslices \
            -o json 2>/dev/null | \
        DRIVER="$driver" python3 -c '
import json
import sys
import os

driver = os.environ.get(
    "DRIVER",
    ""
)

count = 0

try:

    data = json.load(sys.stdin)

    for item in data.get("items", []):

        item_driver = item.get(
            "spec", {}
        ).get(
            "driver",
            ""
        )

        if item_driver == driver:
            count += 1

except Exception:
    pass

print(count)
'
    }


    # ------------------------------------------------------------
    # Count advertised devices for discovered DRA driver
    # ------------------------------------------------------------
    count_dra_devices() {

        local driver="$1"

        if [ -z "$driver" ]; then
            echo "0"
            return
        fi

        kubectl get resourceslices \
            -o json 2>/dev/null | \
        DRIVER="$driver" python3 -c '
import json
import sys
import os

driver = os.environ.get(
    "DRIVER",
    ""
)

total = 0

try:

    data = json.load(sys.stdin)

    for item in data.get("items", []):

        spec = item.get(
            "spec",
            {}
        )

        if spec.get(
            "driver",
            ""
        ) != driver:

            continue

        devices = spec.get(
            "devices",
            []
        )

        total += len(devices)

except Exception:
    pass

print(total)
'
    }


    # ------------------------------------------------------------
    # Find DeviceClass associated with discovered DRA driver
    #
    # DeviceClass name is NOT fixed.
    # ------------------------------------------------------------
    find_candidate_deviceclass() {

        local driver="$1"

        if [ -z "$driver" ]; then
            return
        fi

        kubectl get deviceclasses \
            -o json 2>/dev/null | \
        DRIVER="$driver" python3 -c '
import json
import sys
import os

driver = os.environ.get(
    "DRIVER",
    ""
)

try:

    data = json.load(sys.stdin)

    for item in data.get("items", []):

        name = item.get(
            "metadata",
            {}
        ).get(
            "name",
            ""
        )

        selectors = item.get(
            "spec",
            {}
        ).get(
            "selectors",
            []
        )

        selector_text = json.dumps(
            selectors
        )

        if driver in selector_text:

            print(name)
            sys.exit(0)

except Exception:
    pass
'
    }


    # ------------------------------------------------------------
    # Count all ResourceClaims
    # ------------------------------------------------------------
    count_resourceclaims() {

        kubectl get resourceclaims \
            -A \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

try:

    data = json.load(sys.stdin)

    print(
        len(
            data.get(
                "items",
                []
            )
        )
    )

except Exception:
    print(0)
'
    }


    # ------------------------------------------------------------
    # Count allocated ResourceClaims
    # ------------------------------------------------------------
    count_allocated_claims() {

        kubectl get resourceclaims \
            -A \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

count = 0

try:

    data = json.load(sys.stdin)

    for item in data.get(
        "items",
        []
    ):

        allocation = item.get(
            "status",
            {}
        ).get(
            "allocation"
        )

        if not allocation:
            continue

        devices = allocation.get(
            "devices",
            {}
        )

        results = devices.get(
            "results",
            []
        )

        if results:
            count += 1

except Exception:
    pass

print(count)
'
    }


    # ------------------------------------------------------------
    # Find namespace containing allocated ResourceClaim
    #
    # Namespace name is NOT fixed.
    # ------------------------------------------------------------
    find_gpu_namespace() {

        kubectl get resourceclaims \
            -A \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

try:

    data = json.load(sys.stdin)

    for item in data.get(
        "items",
        []
    ):

        allocation = item.get(
            "status",
            {}
        ).get(
            "allocation"
        )

        if not allocation:
            continue

        devices = allocation.get(
            "devices",
            {}
        )

        results = devices.get(
            "results",
            []
        )

        if results:

            namespace = item.get(
                "metadata",
                {}
            ).get(
                "namespace",
                ""
            )

            if namespace:

                print(namespace)
                sys.exit(0)

except Exception:
    pass
'
    }


    # ------------------------------------------------------------
    # Count Running Pods referencing ResourceClaims
    #
    # Pod names and namespace names are NOT fixed.
    # ------------------------------------------------------------
    count_running_claim_pods() {

        kubectl get pods \
            -A \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

count = 0

try:

    data = json.load(sys.stdin)

    for pod in data.get(
        "items",
        []
    ):

        phase = pod.get(
            "status",
            {}
        ).get(
            "phase",
            ""
        )

        if phase != "Running":
            continue

        claims = pod.get(
            "spec",
            {}
        ).get(
            "resourceClaims",
            []
        )

        if claims:
            count += 1

except Exception:
    pass

print(count)
'
    }


    # ------------------------------------------------------------
    # Find ResourceQuota dynamically
    #
    # Quota name and namespace are NOT fixed.
    #
    # The evaluator searches for a quota containing:
    #
    #   1. Pod limit
    #   2. DRA/device resource limit
    # ------------------------------------------------------------
    find_candidate_quota() {

        kubectl get resourcequota \
            -A \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

try:

    data = json.load(sys.stdin)

    candidates = []

    for item in data.get(
        "items",
        []
    ):

        metadata = item.get(
            "metadata",
            {}
        )

        hard = item.get(
            "spec",
            {}
        ).get(
            "hard",
            {}
        )

        namespace = metadata.get(
            "namespace",
            ""
        )

        name = metadata.get(
            "name",
            ""
        )

        has_pod_limit = (
            "pods" in hard
        )

        has_device_limit = False

        for key in hard.keys():

            key_lower = key.lower()

            if (
                "deviceclass" in key_lower
                or
                "resource.k8s.io/devices" in key_lower
            ):

                has_device_limit = True
                break


        if (
            has_pod_limit
            and
            has_device_limit
        ):

            candidates.append(
                (
                    namespace,
                    name
                )
            )


    if candidates:

        namespace, name = candidates[0]

        print(
            namespace + "|" +
            name
        )

except Exception:
    pass
'
    }


    # ------------------------------------------------------------
    # Get quota capacity dynamically
    # ------------------------------------------------------------
    get_quota_capacity() {

        local quota_name="$1"
        local quota_namespace="$2"

        if [ -z "$quota_name" ] ||
           [ -z "$quota_namespace" ]; then

            echo "0|0"
            return
        fi

        kubectl get resourcequota \
            "$quota_name" \
            -n "$quota_namespace" \
            -o json 2>/dev/null | \
        python3 -c '
import json
import sys

pod_limit = 0
device_limit = 0

try:

    data = json.load(sys.stdin)

    hard = data.get(
        "spec",
        {}
    ).get(
        "hard",
        {}
    )


    # --------------------------------------------------------
    # Pod quota
    # --------------------------------------------------------

    if "pods" in hard:

        try:

            pod_limit = int(
                hard["pods"]
            )

        except Exception:
            pass


    # --------------------------------------------------------
    # DRA device quota
    # --------------------------------------------------------

    for key, value in hard.items():

        key_lower = key.lower()

        if (
            "deviceclass" in key_lower
            or
            "resource.k8s.io/devices" in key_lower
        ):

            try:

                device_limit = max(
                    device_limit,
                    int(value)
                )

            except Exception:
                pass


except Exception:
    pass


print(
    str(pod_limit) +
    "|" +
    str(device_limit)
)
'
    }


    # ============================================================
    # Discover Common Lab Resources
    # ============================================================

    DRA_DRIVER=$(find_dra_driver)

    DRA_DAEMONSET_INFO=$(find_dra_daemonset)

    DEVICECLASS_NAME=$(find_candidate_deviceclass \
        "$DRA_DRIVER")

    GPU_NAMESPACE=$(find_gpu_namespace)

    QUOTA_INFO=$(find_candidate_quota)

    ALLOCATED_CLAIMS=$(count_allocated_claims)

    RUNNING_CLAIM_PODS=$(count_running_claim_pods)

    DRA_DEVICE_COUNT=$(count_dra_devices \
        "$DRA_DRIVER")

    RESOURCE_SLICE_COUNT=$(count_driver_resourceslices \
        "$DRA_DRIVER")

    TOTAL_RESOURCECLAIMS=$(count_resourceclaims)


    # ============================================================
    # TC01 : Verifying DRA Driver
    # ============================================================

    tc1_passed=0
    tc1_score=0
    tc1_status="Fail"
    tc1_obs=""
    tc1_feedback=""

    dra_driver_ok=false

    dra_daemonset_name=""
    dra_daemonset_namespace=""
    dra_daemonset_ready=0
    dra_daemonset_desired=0


    # ------------------------------------------------------------
    # Verify that a DRA driver identity was discovered.
    #
    # No fixed driver name is required.
    # ------------------------------------------------------------

    driver_identity_ok=false

    if [ -n "$DRA_DRIVER" ]; then
        driver_identity_ok=true
    fi


    # ------------------------------------------------------------
    # Verify DRA driver DaemonSet
    #
    # DaemonSet name and namespace are dynamic.
    # ------------------------------------------------------------

    if [ -n "$DRA_DAEMONSET_INFO" ]; then

        IFS='|' read -r \
            dra_daemonset_namespace \
            dra_daemonset_name \
            dra_daemonset_desired \
            dra_daemonset_ready <<< "$DRA_DAEMONSET_INFO"


        if [ "${dra_daemonset_desired:-0}" -ge 1 ] &&
           [ "${dra_daemonset_ready:-0}" -ge 1 ]; then

            dra_driver_ok=true

        fi

    fi


    # ------------------------------------------------------------
    # TC01 PASS condition
    #
    # 1. DRA driver identity discovered from ResourceSlice
    # 2. DRA driver DaemonSet discovered
    # 3. Desired DaemonSet instances >= 1
    # 4. Ready DaemonSet instances >= 1
    #
    # No fixed:
    #   - DaemonSet name
    #   - Namespace
    #   - Container name
    #   - Driver resource name
    # ------------------------------------------------------------

    tc1_obs="DRA Driver: ${DRA_DRIVER:-None}, Driver DaemonSet: ${dra_daemonset_name:-None}, Namespace: ${dra_daemonset_namespace:-None}, Desired: ${dra_daemonset_desired:-0}, Ready: ${dra_daemonset_ready:-0}."


    if [ "$driver_identity_ok" = true ] &&
       [ "$dra_driver_ok" = true ]; then

        tc1_passed=1
        tc1_score=10
        tc1_status="Success"

        tc1_feedback="DRA driver infrastructure was discovered dynamically and the driver DaemonSet is running successfully."

        ((final_score+=10))
        ((total_passed++))

    else

        tc1_score=0
        tc1_status="Fail"

        tc1_feedback="A running DRA driver could not be verified. Deploy the DRA driver and ensure its DaemonSet is running."

        ((total_failed++))

    fi


    # ============================================================
    # TC02 : Verifying DRA Device Discovery
    # ============================================================

    tc2_passed=0
    tc2_score=0
    tc2_status="Fail"
    tc2_obs=""
    tc2_feedback=""

    resourceslice_ok=false


    if [ "${RESOURCE_SLICE_COUNT:-0}" -ge 1 ] &&
       [ "${DRA_DEVICE_COUNT:-0}" -ge 1 ]; then

        resourceslice_ok=true

    fi


    tc2_obs="DRA Driver: ${DRA_DRIVER:-None}, ResourceSlices: ${RESOURCE_SLICE_COUNT:-0}, Advertised Devices: ${DRA_DEVICE_COUNT:-0}."


    if [ "$resourceslice_ok" = true ]; then

        tc2_passed=1
        tc2_score=15
        tc2_status="Success"

        tc2_feedback="DRA ResourceSlice objects were found and devices are being advertised to Kubernetes."

        ((final_score+=15))
        ((total_passed++))

    else

        tc2_score=0
        tc2_status="Fail"

        tc2_feedback="DRA device discovery could not be verified. Ensure the DRA driver publishes ResourceSlice objects containing devices."

        ((total_failed++))

    fi


    # ============================================================
    # TC03 : Verifying DeviceClass
    # ============================================================

    tc3_passed=0
    tc3_score=0
    tc3_status="Fail"
    tc3_obs=""
    tc3_feedback=""

    deviceclass_ok=false


    DEVICECLASS_COUNT=$(kubectl get deviceclasses \
        -o json 2>/dev/null | \
        python3 -c '
import json
import sys

try:

    data = json.load(sys.stdin)

    print(
        len(
            data.get(
                "items",
                []
            )
        )
    )

except Exception:
    print(0)
')


    if [ -n "$DEVICECLASS_NAME" ]; then
        deviceclass_ok=true
    fi


    tc3_obs="DeviceClass: ${DEVICECLASS_NAME:-None}, Total DeviceClasses: ${DEVICECLASS_COUNT:-0}, Associated DRA Driver: ${DRA_DRIVER:-None}."


    if [ "$deviceclass_ok" = true ]; then

        tc3_passed=1
        tc3_score=10
        tc3_status="Success"

        tc3_feedback="A DeviceClass associated with the dynamically discovered DRA driver was successfully verified."

        ((final_score+=10))
        ((total_passed++))

    else

        tc3_score=0
        tc3_status="Fail"

        tc3_feedback="No DeviceClass associated with the discovered DRA driver was found. Create a DeviceClass for the DRA device resource."

        ((total_failed++))

    fi


    # ============================================================
    # TC04 : Verifying ResourceClaim Allocation
    # ============================================================

    tc4_passed=0
    tc4_score=0
    tc4_status="Fail"
    tc4_obs=""
    tc4_feedback=""

    claim_ok=false


    if [ "${ALLOCATED_CLAIMS:-0}" -ge 1 ]; then
        claim_ok=true
    fi


    tc4_obs="Total ResourceClaims: ${TOTAL_RESOURCECLAIMS:-0}, Allocated ResourceClaims: ${ALLOCATED_CLAIMS:-0}, Workload Namespace: ${GPU_NAMESPACE:-None}."


    if [ "$claim_ok" = true ]; then

        tc4_passed=1
        tc4_score=15
        tc4_status="Success"

        tc4_feedback="At least one ResourceClaim was successfully allocated to a DRA device."

        ((final_score+=15))
        ((total_passed++))

    else

        tc4_score=0
        tc4_status="Fail"

        tc4_feedback="No allocated ResourceClaim was found. Create a ResourceClaim and allow DRA to allocate a device."

        ((total_failed++))

    fi


    # ============================================================
    # TC05 : Verifying GPU Workload Scheduling
    # ============================================================

    tc5_passed=0
    tc5_score=0
    tc5_status="Fail"
    tc5_obs=""
    tc5_feedback=""

    scheduling_ok=false


    if [ "${RUNNING_CLAIM_PODS:-0}" -ge 1 ]; then
        scheduling_ok=true
    fi


    tc5_obs="GPU Namespace: ${GPU_NAMESPACE:-None}, Running Pods referencing ResourceClaims: ${RUNNING_CLAIM_PODS:-0}."


    if [ "$scheduling_ok" = true ]; then

        tc5_passed=1
        tc5_score=15
        tc5_status="Success"

        tc5_feedback="A running Kubernetes workload referencing a ResourceClaim was verified, demonstrating successful device-aware workload scheduling."

        ((final_score+=15))
        ((total_passed++))

    else

        tc5_score=0
        tc5_status="Fail"

        tc5_feedback="No running Pod referencing a ResourceClaim was found. Verify that the DRA workload is scheduled and running."

        ((total_failed++))

    fi


    # ============================================================
    # TC06 : Verifying ResourceQuota
    # ============================================================

    tc6_passed=0
    tc6_score=0
    tc6_status="Fail"
    tc6_obs=""
    tc6_feedback=""

    quota_ok=false

    quota_namespace=""
    quota_name=""

    quota_pods=""
    quota_device_limit=""


    if [ -n "$QUOTA_INFO" ]; then

        IFS='|' read -r \
            quota_namespace \
            quota_name <<< "$QUOTA_INFO"


        if [ -n "$quota_name" ] &&
           [ -n "$quota_namespace" ]; then

            QUOTA_CAPACITY=$(get_quota_capacity \
                "$quota_name" \
                "$quota_namespace")


            IFS='|' read -r \
                quota_pods \
                quota_device_limit <<< "$QUOTA_CAPACITY"


            if [ -n "$quota_pods" ] &&
               [ -n "$quota_device_limit" ] &&
               [ "$quota_pods" -ge 1 ] &&
               [ "$quota_device_limit" -ge 1 ]; then

                quota_ok=true

            fi

        fi

    fi


    tc6_obs="ResourceQuota: ${quota_name:-None}, Namespace: ${quota_namespace:-None}, Pod Limit: ${quota_pods:-Not Configured}, Device/Resource Limit: ${quota_device_limit:-Not Configured}."


    if [ "$quota_ok" = true ]; then

        tc6_passed=1
        tc6_score=15
        tc6_status="Success"

        tc6_feedback="A ResourceQuota was discovered with both a Pod limit and a DRA device/resource consumption limit."

        ((final_score+=15))
        ((total_passed++))

    else

        tc6_score=0
        tc6_status="Fail"

        tc6_feedback="A valid ResourceQuota with both workload and DRA device/resource limits could not be verified."

        ((total_failed++))

    fi


    # ============================================================
    # TC07 : Verifying Capacity Optimization
    # ============================================================

    tc7_passed=0
    tc7_score=0
    tc7_status="Fail"
    tc7_obs=""
    tc7_feedback=""

    capacity_devices_ok=false
    capacity_workloads_ok=false
    capacity_quota_ok=false

    final_device_count="${DRA_DEVICE_COUNT:-0}"
    final_workload_count="${RUNNING_CLAIM_PODS:-0}"

    final_device_quota=0
    final_pod_quota=0


    # ------------------------------------------------------------
    # Read final quota limits
    # ------------------------------------------------------------

    if [ -n "$quota_name" ] &&
       [ -n "$quota_namespace" ]; then

        FINAL_QUOTA_CAPACITY=$(get_quota_capacity \
            "$quota_name" \
            "$quota_namespace")


        IFS='|' read -r \
            final_pod_quota \
            final_device_quota <<< "$FINAL_QUOTA_CAPACITY"

    fi


    # ------------------------------------------------------------
    # Final DRA device capacity
    # ------------------------------------------------------------

    if [ "${final_device_count:-0}" -ge "$MIN_FINAL_DEVICES" ]; then
        capacity_devices_ok=true
    fi


    # ------------------------------------------------------------
    # Final running workload capacity
    # ------------------------------------------------------------

    if [ "${final_workload_count:-0}" -ge "$MIN_FINAL_WORKLOADS" ]; then
        capacity_workloads_ok=true
    fi


    # ------------------------------------------------------------
    # Final quota capacity
    #
    # Both Pod quota and DRA device quota must support
    # the optimized workload capacity.
    # ------------------------------------------------------------

    if [ "${final_pod_quota:-0}" -ge "$MIN_FINAL_WORKLOADS" ] &&
       [ "${final_device_quota:-0}" -ge "$MIN_FINAL_DEVICES" ]; then

        capacity_quota_ok=true

    fi


    tc7_obs="Final DRA Devices: ${final_device_count}, Final Running GPU Workloads: ${final_workload_count}, Final Pod Quota: ${final_pod_quota:-0}, Final Device Quota: ${final_device_quota:-0}, Required Devices: ${MIN_FINAL_DEVICES}, Required Workloads: ${MIN_FINAL_WORKLOADS}."


    if [ "$capacity_devices_ok" = true ] &&
       [ "$capacity_workloads_ok" = true ] &&
       [ "$capacity_quota_ok" = true ]; then

        tc7_passed=1
        tc7_score=20
        tc7_status="Success"

        tc7_feedback="DRA device capacity and Kubernetes quota capacity were tuned to support the required optimized GPU workload capacity."

        ((final_score+=20))
        ((total_passed++))

    else

        tc7_score=0
        tc7_status="Fail"


        if [ "$capacity_devices_ok" != true ]; then

            tc7_feedback="Final advertised DRA device capacity is below the required optimized capacity. Increase the configured DRA device capacity."

        elif [ "$capacity_quota_ok" != true ]; then

            tc7_feedback="DRA device capacity is sufficient, but the Pod and/or DRA device quota has not been increased to support the optimized capacity."

        elif [ "$capacity_workloads_ok" != true ]; then

            tc7_feedback="Capacity configuration was found, but the required number of GPU workloads are not running."

        else

            tc7_feedback="Capacity optimization could not be completely verified."

        fi


        ((total_failed++))

    fi


    # ============================================================
    # FINAL SCORE
    # ============================================================

    formatted_grade=$(printf "%.2f" "$final_score")


    # ============================================================
    # JSON REPORT
    # ============================================================

    reportData=$(cat <<EOF
{
    "evaluationdetails": {
        "evaluationbreakup": [
            {
                "name": "Verifying DRA Driver",
                "totaltestcase": "1",
                "testcasepassed": "$tc1_passed",
                "maxmark": "10",
                "score": "$tc1_score",
                "status": "$tc1_status",
                "feedback": "$tc1_feedback",
                "expertises": {
                    "expertise": {
                        "name": "DRA Infrastructure",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying DRA Driver",
                                    "description": "$tc1_obs",
                                    "shortdescription": "$tc1_feedback",
                                    "maxmark": "10",
                                    "score": "$tc1_score",
                                    "status": "$tc1_status"
                                }
                            ]
                        }
                    }
                }
            },
            {
                "name": "Verifying DRA Device Discovery",
                "totaltestcase": "1",
                "testcasepassed": "$tc2_passed",
                "maxmark": "15",
                "score": "$tc2_score",
                "status": "$tc2_status",
                "feedback": "$tc2_feedback",
                "expertises": {
                    "expertise": {
                        "name": "Device Discovery",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying DRA Device Discovery",
                                    "description": "$tc2_obs",
                                    "shortdescription": "$tc2_feedback",
                                    "maxmark": "15",
                                    "score": "$tc2_score",
                                    "status": "$tc2_status"
                                }
                            ]
                        }
                    }
                }
            },
            {
                "name": "Verifying DeviceClass",
                "totaltestcase": "1",
                "testcasepassed": "$tc3_passed",
                "maxmark": "10",
                "score": "$tc3_score",
                "status": "$tc3_status",
                "feedback": "$tc3_feedback",
                "expertises": {
                    "expertise": {
                        "name": "DRA Device Classification",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying DeviceClass",
                                    "description": "$tc3_obs",
                                    "shortdescription": "$tc3_feedback",
                                    "maxmark": "10",
                                    "score": "$tc3_score",
                                    "status": "$tc3_status"
                                }
                            ]
                        }
                    }
                }
            },
            {
                "name": "Verifying ResourceClaim Allocation",
                "totaltestcase": "1",
                "testcasepassed": "$tc4_passed",
                "maxmark": "15",
                "score": "$tc4_score",
                "status": "$tc4_status",
                "feedback": "$tc4_feedback",
                "expertises": {
                    "expertise": {
                        "name": "Dynamic Resource Allocation",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying ResourceClaim Allocation",
                                    "description": "$tc4_obs",
                                    "shortdescription": "$tc4_feedback",
                                    "maxmark": "15",
                                    "score": "$tc4_score",
                                    "status": "$tc4_status"
                                }
                            ]
                        }
                    }
                }
            },
            {
                "name": "Verifying GPU Workload Scheduling",
                "totaltestcase": "1",
                "testcasepassed": "$tc5_passed",
                "maxmark": "15",
                "score": "$tc5_score",
                "status": "$tc5_status",
                "feedback": "$tc5_feedback",
                "expertises": {
                    "expertise": {
                        "name": "Kubernetes Scheduling",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying GPU Workload Scheduling",
                                    "description": "$tc5_obs",
                                    "shortdescription": "$tc5_feedback",
                                    "maxmark": "15",
                                    "score": "$tc5_score",
                                    "status": "$tc5_status"
                                }
                            ]
                        }
                    }
                }
            },
            {
                "name": "Verifying ResourceQuota",
                "totaltestcase": "1",
                "testcasepassed": "$tc6_passed",
                "maxmark": "15",
                "score": "$tc6_score",
                "status": "$tc6_status",
                "feedback": "$tc6_feedback",
                "expertises": {
                    "expertise": {
                        "name": "Kubernetes Resource Quotas",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying ResourceQuota",
                                    "description": "$tc6_obs",
                                    "shortdescription": "$tc6_feedback",
                                    "maxmark": "15",
                                    "score": "$tc6_score",
                                    "status": "$tc6_status"
                                }
                            ]
                        }
                    }
                }
            },
            {
                "name": "Verifying Capacity Optimization",
                "totaltestcase": "1",
                "testcasepassed": "$tc7_passed",
                "maxmark": "20",
                "score": "$tc7_score",
                "status": "$tc7_status",
                "feedback": "$tc7_feedback",
                "expertises": {
                    "expertise": {
                        "name": "Capacity Optimization",
                        "testcases": {
                            "testcase": [
                                {
                                    "visible": "yes",
                                    "name": "Verifying Capacity Optimization",
                                    "description": "$tc7_obs",
                                    "shortdescription": "$tc7_feedback",
                                    "maxmark": "20",
                                    "score": "$tc7_score",
                                    "status": "$tc7_status"
                                }
                            ]
                        }
                    }
                }
            }
        ],
        "consolidatedtestcase": {
            "totaltestcases": "7",
            "passedtestcase": "$total_passed",
            "failedtestcase": "$total_failed"
        }
    }
}
EOF
)


    # ============================================================
    # Final Output
    # ============================================================

    echo "Grade:=>>$formatted_grade <reportData>$reportData</reportData>"
}


# ================================================================
# Execute evaluator when script is run directly
# ================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    evaluate_project "$@"

fi 