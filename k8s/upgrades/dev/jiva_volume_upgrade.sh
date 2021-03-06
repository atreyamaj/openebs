#!/usr/bin/env bash
################################################################
# STEP: Get Persistent Volume (PV) name as argument            #
#                                                              #
# NOTES: Obtain the pv to upgrade via "kubectl get pv"         #
################################################################

target_upgrade_version="0.8.2"
current_version="0.8.1"

function usage() {
    echo
    echo "Usage:"
    echo
    echo "$0 <pv-name>"
    echo
    echo "  <pv-name> Get the PV name using: kubectl get pv"
    exit 1
}

function setDeploymentRecreateStrategy() {
    dns=$1 # deployment namespace
    dn=$2  # deployment name
    currStrategy=`kubectl get deploy -n $dns $dn -o jsonpath="{.spec.strategy.type}"`
    rc=$?; if [ $rc -ne 0 ]; then echo "Failed to get the deployment stratergy for $dn | Exit code: $rc"; exit; fi

    if [ $currStrategy != "Recreate" ]; then
       kubectl patch deployment --namespace $dns --type json $dn -p "$(cat patch-strategy-recreate.json)"
       rc=$?; if [ $rc -ne 0 ]; then echo "Failed to patch the deployment $dn | Exit code: $rc"; exit; fi
       echo "Deployment upgrade strategy set as recreate"
    else
       echo "Deployment upgrade strategy was already set as recreate"
    fi
}

if [ "$#" -ne 1 ]; then
    usage
fi

pv=$1
replica_node_label="openebs-jiva"

source snapshotdata_upgrade.sh

# Check if pv exists
kubectl get pv $pv &>/dev/null;check_pv=$?
if [ $check_pv -ne 0 ]; then
    echo "$pv not found";exit 1;
fi

# Check if CASType is jiva
cas_type=`kubectl get pv $pv -o jsonpath="{.metadata.annotations.openebs\.io/cas-type}"`
if [ $cas_type != "jiva" ]; then
    echo "Jiva volume not found";exit 1;
fi

ns=`kubectl get pv $pv -o jsonpath="{.spec.claimRef.namespace}"`
sc_name=`kubectl get pv $pv -o jsonpath="{.spec.storageClassName}"`
sc_res_ver=`kubectl get sc $sc_name -n $ns -o jsonpath="{.metadata.resourceVersion}"`

#################################################################
# STEP: Generate deploy, replicaset and container names from PV #
#                                                               #
# NOTES: Ex: If PV="pvc-cec8e86d-0bcc-11e8-be1c-000c298ff5fc"   #
#                                                               #
# ctrl-dep: pvc-cec8e86d-0bcc-11e8-be1c-000c298ff5fc-ctrl       #
#################################################################

c_dep=$(kubectl get deploy -n $ns -l openebs.io/persistent-volume=$pv,openebs.io/controller=jiva-controller -o jsonpath="{.items[*].metadata.name}")
r_dep=$(kubectl get deploy -n $ns -l openebs.io/persistent-volume=$pv,openebs.io/replica=jiva-replica -o jsonpath="{.items[*].metadata.name}")
c_svc=$(kubectl get svc -n $ns -l openebs.io/persistent-volume=$pv -o jsonpath="{.items[*].metadata.name}")
c_name=$(kubectl get deploy -n $ns $c_dep -o jsonpath="{range .spec.template.spec.containers[*]}{@.name}{'\n'}{end}" | grep "con")
r_name=$(kubectl get deploy -n $ns $r_dep -o jsonpath="{range .spec.template.spec.containers[*]}{@.name}{'\n'}{end}" | grep "con")

# Fetch the older target and replica - ReplicaSet objects which need to be
# deleted before upgrading. If not deleted, the new pods will be stuck in
# creating state - due to affinity rules.

c_rs=$(kubectl get rs -o name --namespace $ns -l openebs.io/persistent-volume=$pv,openebs.io/controller=jiva-controller | cut -d '/' -f 2)
r_rs=$(kubectl get rs -o name --namespace $ns -l openebs.io/persistent-volume=$pv,openebs.io/replica=jiva-replica | cut -d '/' -f 2)

################################################################
# STEP: Update patch files with appropriate resource names     #
#                                                              #
# NOTES: Placeholder for resourcename in the patch files are   #
# replaced with respective values derived from the PV in the   #
# previous step                                                #
################################################################

# Check if openebs resources exist and provisioned version is 0.8

if [[ -z $c_rs ]]; then
    echo "Target Replica set not found"; exit 1;
fi

if [[ -z $r_rs ]]; then
    echo "Replica Replica set not found"; exit 1;
fi

if [[ -z $c_dep ]]; then
    echo "Target deployment not found"; exit 1;
fi

if [[ -z $r_dep ]]; then
    echo "Replica deployment not found"; exit 1;
fi

if [[ -z $c_svc ]]; then
    echo "Target service not found"; exit 1;
fi

if [[ -z $r_name ]]; then
    echo "Replica container not found"; exit 1;
fi

if [[ -z $c_name ]]; then
    echo "Target container not found"; exit 1;
fi

controller_version=`kubectl get deployment $c_dep -n $ns -o jsonpath='{.metadata.labels.openebs\.io/version}'`
if [[ "$controller_version" != "$current_version" ]] && [[ "$controller_version" != "$target_upgrade_version" ]]; then
    echo "Current Target deployment $c_dep version is not $current_version or $target_upgrade_version";exit 1;
fi
replica_version=`kubectl get deployment $r_dep -n $ns -o jsonpath='{.metadata.labels.openebs\.io/version}'`
if [[ "$replica_version" != "$current_version" ]] && [[ "$replica_version" != "$target_upgrade_version" ]]; then
    echo "Current Replica deployment $r_dep version is not $current_version or $target_upgrade_version";exit 1;
fi

controller_svc_version=`kubectl get svc $c_svc -n $ns -o jsonpath='{.metadata.labels.openebs\.io/version}'`
if [[ "$controller_svc_version" != $current_version ]] && [[ "$controller_svc_version" != "$target_upgrade_version" ]] ; then
    echo "Current Target service $c_svc version is not $current_version or $target_upgrade_version";exit 1;
fi

# Get the number of replicas configured.
# This field is currently not used, but can add additional validations
# based on the nodes and expected number of replicas
rep_count=`kubectl get deploy $r_dep --namespace $ns -o jsonpath="{.spec.replicas}"`

# Get the list of nodes where replica pods are running, delimited by ':'
rep_nodenames=`kubectl get pods -n $ns \
 -l "openebs.io/persistent-volume=$pv" -l "openebs.io/replica=jiva-replica" \
 -o jsonpath="{range .items[*]}{@.spec.nodeName}:{end}"`

echo "Checking if the node with replica pod has been labeled with $replica_node_label"
for rep_node in `echo $rep_nodenames | tr ":" " "`; do
    nl="";nl=`kubectl get nodes $rep_node -o jsonpath="{.metadata.labels.openebs-pv-$pv}"`
    if [  -z "$nl" ];
    then
       echo "Labeling $rep_node";
       kubectl label node $rep_node "openebs-pv-${pv}=$replica_node_label"
    fi
done


sed -u "s/@r_name@/$r_name/g" | sed -u "s/@target_version@/$target_upgrade_version/g"  > jiva-replica-patch.json
sed -u "s/@target_version@/$target_upgrade_version/g" > jiva-target-patch.json
sed -u "s/@target_version@/$target_upgrade_version/g" > jiva-target-svc-patch.json

#################################################################################
# STEP: Patch OpenEBS volume deployments (jiva-target, jiva-replica & jiva-svc) #
#################################################################################

# PATCH JIVA REPLICA DEPLOYMENT ####
if [[ "$replica_version" != "$target_upgrade_version" ]]; then
    echo "Upgrading Replica Deployment to $target_upgrade_version"

    # Setting the update stratergy to recreate
    setDeploymentRecreateStrategy $ns $r_dep

    kubectl patch deployment --namespace $ns $r_dep -p "$(cat jiva-replica-patch.json)"
    rc=$?; if [ $rc -ne 0 ]; then echo "Failed to patch the deployment $r_dep | Exit code: $rc"; exit; fi

    kubectl delete rs $r_rs --namespace $ns
    rc=$?; if [ $rc -ne 0 ]; then echo "Failed to delete ReplicaSet $r_rs  | Exit code: $rc"; exit; fi

    rollout_status=$(kubectl rollout status --namespace $ns deployment/$r_dep)
    rc=$?; if [[ ($rc -ne 0) || !($rollout_status =~ "successfully rolled out") ]];
    then echo " RollOut for $r_dep failed | Exit code: $rc"; exit; fi
else
    echo "Replica Deployment $r_dep is already at $target_upgrade_version"
fi

# #### PATCH TARGET DEPLOYMENT ####
if [[ "$controller_version" != "$target_upgrade_version" ]]; then
    echo "Upgrading Target Deployment to $target_upgrade_version"

    # Setting the update stratergy to recreate
    setDeploymentRecreateStrategy $ns $c_dep

    kubectl patch deployment  --namespace $ns $c_dep -p "$(cat jiva-target-patch.json)"
    rc=$?; if [ $rc -ne 0 ]; then echo "Failed to patch deployment $c_dep | Exit code: $rc"; exit; fi

    kubectl delete rs $c_rs --namespace $ns
    rc=$?; if [ $rc -ne 0 ]; then echo "Failed to patch deployment $c_rs | Exit code: $rc"; exit; fi

    rollout_status=$(kubectl rollout status --namespace $ns  deployment/$c_dep)
    rc=$?; if [[ ($rc -ne 0) || !($rollout_status =~ "successfully rolled out") ]];
    then echo " Failed to patch the deployment | Exit code: $rc"; exit; fi
else
    echo "Controller Deployment $c_dep is already at $target_upgrade_version"

fi

# #### PATCH TARGET SERVICE ####
if [[ "$controller_svc_version" != "$target_upgrade_version" ]]; then
    echo "Upgrading Target Service to $target_upgrade_version"
    kubectl patch service --namespace $ns $c_svc -p "$(cat jiva-target-svc-patch.json)"
    rc=$?; if [ $rc -ne 0 ]; then echo "Failed to patch the service $svc | Exit code: $rc"; exit; fi
else
    echo "Controller service $c_svc is already at $target_upgrade_version"
fi

##Patch jiva snapshotdata crs related to pv
run_snapshotdata_upgrades $pv
rc=$?
if [ $rc -ne 0 ]; then
   exit 1
fi

echo "Clearing temporary files"
rm jiva-replica-patch.json
rm jiva-target-patch.json
rm jiva-target-svc-patch.json

echo "Successfully upgraded $pv to $target_upgrade_version Please run your application checks."
exit 0

