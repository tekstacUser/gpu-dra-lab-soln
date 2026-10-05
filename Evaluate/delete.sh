#!/bin/bash

echo "=============================================="
echo " Cleaning GPU DRA Lab"
echo "=============================================="

echo
echo "Deleting GPU workloads and quota..."

kubectl delete namespace gpu-lab --ignore-not-found=true

echo
echo "Deleting DRA driver..."

kubectl delete namespace dra-tutorial --ignore-not-found=true

echo
echo "Deleting DeviceClass..."

kubectl delete deviceclass gpu.example.com \
    --ignore-not-found=true

echo
echo "Deleting PriorityClass..."

kubectl delete priorityclass dra-driver-high-priority \
    --ignore-not-found=true

echo
echo "Deleting ClusterRole..."

kubectl delete clusterrole dra-example-driver-role \
    --ignore-not-found=true

echo
echo "Deleting ClusterRoleBinding..."

kubectl delete clusterrolebinding dra-example-driver-role-binding \
    --ignore-not-found=true

echo
echo "=============================================="
echo " GPU DRA Lab Cleanup Completed"
echo "=============================================="

echo
read -p "Do you want to delete the Minikube cluster also? (y/N): " answer

if [[ "$answer" =~ ^[Yy]$ ]]; then
    minikube delete
    echo "Minikube cluster deleted."
else
    echo "Minikube cluster retained."
fi