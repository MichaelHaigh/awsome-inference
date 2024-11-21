#!/bin/bash
set -euo pipefail

FSXN_NAS_SC_NAME="fsx-netapp-file"
FSXN_SAN_SC_NAME="fsx-netapp-block"
BACKEND_NAME_PREFIX="backend-fsx-ontap"

eks_svm_name="PLACEHOLDER_SVM_NAME"
fsx_filesystem_id="PLACEHOLDER_FSXFS_ID"
svm_password="PLACEHOLDER_SECRET_ARN"

volume_snapshot() {
        kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-5.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
        kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-5.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
        kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-5.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
        sleep 15
        kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-5.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
        kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-5.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
        sleep 15
        kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-trident-snapclass
driver: csi.trident.netapp.io
deletionPolicy: Delete
EOF
}

create_backend() {
        suffix=$1
        echo "    --> creating ${suffix} Trident backend"
        kubectl apply -f - <<EOF
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ${BACKEND_NAME_PREFIX}-${suffix}
  namespace: trident
spec:
  version: 1
  storageDriverName: ontap-${suffix}
  svm: ${eks_svm_name}
  aws:
    fsxFilesystemID: ${fsx_filesystem_id}
  credentials:
    name: ${svm_password}
    type: awsarn
EOF
}

create_block_storageclass() {
        echo "    --> creating FSxN Block storage class"
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${FSXN_SAN_SC_NAME}
provisioner: csi.trident.netapp.io
parameters:
  backendType: 'ontap-san'
  fsType: 'ext4'
allowVolumeExpansion: True
EOF
}

create_file_storageclass() {
        echo "    --> updating default storage class and creating FSxN File storage class"
        kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${FSXN_NAS_SC_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: 'true'
provisioner: csi.trident.netapp.io
parameters:
  backendType: 'ontap-nas'
  fsType: 'ext4'
allowVolumeExpansion: True
EOF
}

######################################
# Install Volume Snapshot Components #
######################################
echo "--> installing volume snapshot components"
volume_snapshot

###########################
# Create Trident Backends #
###########################
for suffix in "san" "nas"; do
        echo "--> determining if Trident ${suffix} backend needs to be created"
        set +e
        kubectl -n trident get TridentBackendConfig ${BACKEND_NAME_PREFIX}-${suffix} >> /dev/null 2>&1
        BACKEND_EXISTS=$?
        set -e
        if [[ $BACKEND_EXISTS -eq 0 ]]; then
                echo "     --> Trident ${suffix} backend already exists, skipping creation"
        else
                create_backend "${suffix}"
                echo "--> sleeping for 10 seconds"
                sleep 10
        fi
done

#############################
# Create Block StorageClass #
#############################
echo "--> determining if FSxN Block storage class needs to be created"
set +e
kubectl get sc ${FSXN_SAN_SC_NAME} >> /dev/null 2>&1
SC_EXISTS=$?
set -e
if [[ $SC_EXISTS -eq 0 ]]; then
        echo "     --> FSxN Block storage class already exists, skipping creation"
else
        create_block_storageclass
fi

############################
# Create File StorageClass #
############################
echo "--> determining if FSxN File storage class needs to be created"
set +e
kubectl get sc ${FSXN_NAS_SC_NAME} >> /dev/null 2>&1
SC_EXISTS=$?
set -e
if [[ $SC_EXISTS -eq 0 ]]; then
        echo "     --> FSxN File storage class already exists, skipping creation"
else
        create_file_storageclass
fi
