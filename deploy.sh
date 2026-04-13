#!/bin/bash
set -e

WORKING_DIR="test_deployment"

# clean it up if it already exists
rm -rf "$WORKING_DIR"


# Create the Base and overlay directories for both application
mkdir -p "$WORKING_DIR/base/postgres"
mkdir -p "$WORKING_DIR/base/fact-backend"
mkdir -p "$WORKING_DIR/base/fact-frontend"
mkdir -p "$WORKING_DIR/overlay"

# Create the base deployment files for the application; starting with the pvc, configmap, secrets, services and deployement
cat <<EOF > "$WORKING_DIR/base/postgres/postgres-pvc.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 1Gi
EOF


# imperative commands to create the configmap, secrets, services and deployment for the application

kubectl create configmap postgres-config --from-literal=POSTGRES_DB=factsdb --from-literal=POSTGRES_HOST=postgres-svc --from-literal=POSTGRES_PORT="5432" --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-configmap.yaml"

# Create the secrets for the application
kubectl create secret generic postgres-cred --from-literal=POSTGRES_PASSWORD=postgres --from-literal=POSTGRES_USER=admin --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-secrets.yaml"

# Create the service for the application
kubectl create svc clusterip postgres-svc --tcp=5432:5432 --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-service.yaml"

# Create the deployment for the application
kubectl create deployment postgres --image=postgres:15-alpine --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-deployment.yaml"

# Imperative command to create the fact application deployment
kubectl create deployment fact-backend-deployment --image=succesc/fact-app:v3 --port=5000 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-backend/backend-deployment.yaml"

# Imperative command to create the service for the fact application
kubectl create svc clusterip backend-svc --tcp=5000:5000 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-backend/backend-service.yaml"

# create the configmap for the fact-frontend application containing the index.html file 
kubectl create configmap frontend-html-index --from-file=index.html=./index.html --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-configmap.yaml"

# create the configmap for the fact-frontend application containing the nginx.conf file
kubectl create configmap frontend-nginx-conf --from-file=nginx.conf=./default.conf --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-nginx-configmap.yaml"

# Create the deployment for the fact-frontend application using a nginx:alpine image and mount the configmaps for the index.html and nginx.conf files
kubectl create deployment fact-frontend-deployment --image=nginx:alpine --port=80 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-deployment.yaml"

# Create the service for the fact-frontend application
kubectl create svc nodeport frontend-svc --tcp=80:80 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-service.yaml"



#create the kustomization.yaml file for the base postgres application and the fact application
cat <<EOF > "$WORKING_DIR/base/postgres/kustomization.yaml"
resources:
- postgres-pvc.yaml
- postgres-configmap.yaml
- postgres-secrets.yaml
- postgres-service.yaml
- postgres-deployment.yaml

labels:
- pairs:
    app: postgres-app
  includeSelectors: true
  includeTemplates: true
CommonAnnotations:
  Pager: This was deployed by Su's CKAD Lab
EOF

# Create the kustomization.yaml file for the base fact backend application
cat <<EOF > "$WORKING_DIR/base/fact-backend/kustomization.yaml"
resources:
- backend-deployment.yaml
- backend-service.yaml

labels:
- pairs:
    app: fact-backend
  includeSelectors: true
  includeTemplates: true
CommonAnnotations:
  Pager: This was deployed by Su's CKAD Lab
EOF


# Create the kustomization.yaml file for the base fact-frontend application
cat <<EOF > "$WORKING_DIR/base/fact-frontend/kustomization.yaml"
resources:
- frontend-configmap.yaml
- frontend-nginx-configmap.yaml
- frontend-deployment.yaml
- frontend-service.yaml

labels:
- pairs:
    app: fact-frontend
  includeSelectors: true
  includeTemplates: true
CommonAnnotations:
  Pager: This was deployed by Su's CKAD Lab
EOF


# create one overlay for the whole namespace
mkdir -p "$WORKING_DIR/overlay/test-environment"

# create the namespace for the application and add the necessary labels for the pod security policies
cat <<EOF > "$WORKING_DIR/overlay/test-environment/namespace.yaml"
apiVersion: v1
kind: Namespace
metadata:
    name: test-app
    labels:
        pod-security.kubernetes.io/enforce: privileged
EOF


# Imperative command to create the resouce quota for the namespace and add the necessary limits for the cpu and memory resources
kubectl create resourcequota test-app-rq --namespace=test-app --hard=cpu=2,memory=4Gi --dry-run=client -o yaml > "$WORKING_DIR/overlay/test-environment/resource-quota.yaml"

# Create a Limit Range for the namespace to set default resource limits for the containers
cat <<EOF > "$WORKING_DIR/overlay/test-environment/limit-range.yaml"
apiVersion: v1
kind: LimitRange
metadata:
  name: test-app-limit
  namespace: test-app
spec:
  limits:
  - default:
      cpu: 200m
      memory: 256Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    type: Container
EOF


# Creat the patch file for the postgres deployment containing the env variable, mount path and volumes
cat <<'EOF' > "$WORKING_DIR/overlay/test-environment/postgres-deployment-container-patch.yaml"
- op: add
  path: /spec/template/spec/containers/0/env
  value:
  - name: PGDATA
    value: "/var/lib/postgresql/data/pgdata"
  - name: POSTGRES_INITDB_ARGS
    value: "--locale=C.UTF-8"
  - name: POSTGRES_DB
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_DB
  - name: POSTGRES_USER
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_USER
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_PASSWORD

- op: add
  path: /spec/template/spec/volumes
  value:
  - name: pvc-volume
    persistentVolumeClaim:
      claimName: postgres-pvc

- op: add
  path: /spec/template/spec/containers/0/volumeMounts
  value:
  - name: pvc-volume
    mountPath: /var/lib/postgresql/data
EOF


# Create the overlay kustomization.yaml file for the overlay directory
cat <<EOF > "$WORKING_DIR/overlay/test-environment/kustomization.yaml"
resources:
- ../../base/postgres
- ../../base/fact-backend
- ../../base/fact-frontend
- namespace.yaml
- resource-quota.yaml
- limit-range.yaml

namespace: test-app

patches:
- target:
    kind: Deployment
    name: postgres
  path: postgres-deployment-container-patch.yaml

- target:
    kind: Deployment
    name: fact-backend-deployment
  path: fact-backend-deployment-patch.yaml

- target:
    kind: Deployment
    name: fact-frontend-deployment
  path: fact-frontend-deployment-patch.yaml

EOF



# Create the overlay patch file for the fact application deployment containing the env variable, mount path and volumes
cat <<'EOF' > "$WORKING_DIR/overlay/test-environment/fact-backend-deployment-patch.yaml"
- op: add
  path: /spec/template/spec/containers/0/env
  value:
  - name: POSTGRES_USER
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_USER
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_PASSWORD
  - name: POSTGRES_DB
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_DB
  - name: POSTGRES_HOST
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_HOST
  - name: POSTGRES_PORT
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_PORT
  - name: DATABASE_URL
    value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)"

- op: add
  path: /spec/template/spec/initContainers
  value:
  - name: wait-for-db
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z $(POSTGRES_HOST) $(POSTGRES_PORT); do echo "Waiting for database..."; sleep 5; done;']
    env:
    - name: POSTGRES_HOST
      valueFrom:
        configMapKeyRef:
          name: postgres-config
          key: POSTGRES_HOST
    - name: POSTGRES_PORT
      valueFrom:
        configMapKeyRef:
          name: postgres-config
          key: POSTGRES_PORT
EOF

# Create the overlay patch file for the fact-frontend application deployment containing the, mount path and volumes
cat <<'EOF' > "$WORKING_DIR/overlay/test-environment/fact-frontend-deployment-patch.yaml"
- op: add
  path: /spec/template/spec/volumes
  value:
  - name: html-index-volume
    configMap:
      name: frontend-html-index
  - name: nginx-conf-volume
    configMap:
      name: frontend-nginx-conf
- op: add
  path: /spec/template/spec/containers/0/volumeMounts
  value:
  - name: html-index-volume
    mountPath: /usr/share/nginx/html/index.html
    subPath: index.html
    readOnly: true
  - name: nginx-conf-volume
    mountPath: /etc/nginx/conf.d/default.conf
    subPath: nginx.conf
    readOnly: true
EOF

#run kustomize to view the final manifest for the overlay directory
kubectl kustomize "$WORKING_DIR/overlay/test-environment"


# sleep for 10 seconds to allow the user to view the final manifest before applying it to the cluster or deleting the working directory
#sleep 120

#confirm with the user if they want to apply the manifest to the cluster
read -p "Do you want to apply the manifest to the cluster? (y/n) " REPLY
if [[ "$REPLY" == "y" ]]; then
    kubectl apply -k "$WORKING_DIR/overlay/test-environment"
fi





