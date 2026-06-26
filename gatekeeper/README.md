# Gatekeeper

This folder contains the Gatekeeper policy enforcement guidance for AKS in the AKS Production Accelerator.

## Overview

Gatekeeper is the Open Policy Agent (OPA) admission controller for Kubernetes. It enables policy enforcement by validating Kubernetes manifests before they are persisted and by auditing existing resources.

This README describes:
- how to install Gatekeeper in an AKS cluster
- how to configure Gatekeeper templates and constraints
- how to verify Gatekeeper is running and enforcing policies
- how to manage Gatekeeper in production

## Prerequisites

- An AKS cluster with cluster-admin access
- `kubectl` configured to connect to the target cluster
- Optional: `az` CLI if installing from Azure or managing AKS context

## Install Gatekeeper

### Option 1: Install from the official release manifest

1. Apply the official Gatekeeper release manifest:

   ```powershell
   kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml
   ```

2. Verify the Gatekeeper pods are running:

   ```powershell
   kubectl get pods -n gatekeeper-system
   kubectl get deployments -n gatekeeper-system
   ```

### Option 2: Install using Helm

If you prefer Helm, use the Gatekeeper Helm chart instead:

```powershell
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update
helm install gatekeeper gatekeeper/gatekeeper --namespace gatekeeper-system --create-namespace
```

Then verify the deployment:

```powershell
kubectl get pods -n gatekeeper-system
kubectl get svc -n gatekeeper-system
```

## Configure Gatekeeper

Gatekeeper policies are defined with two objects:
- `ConstraintTemplate` — the policy logic using Rego
- `Constraint` — the policy instance that applies to Kubernetes resources

### Example 1: Deny pods using `latest` images

Create a `ConstraintTemplate` that checks container image tags.

```yaml
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8sforbidlatest
spec:
  crd:
    spec:
      names:
        kind: K8sForbidLatest
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sforbidlatest

        violation[{
          "msg": msg,
          "details": {"container": container.name, "image": container.image}
        }] {
          container := input.review.object.spec.containers[_]
          endswith(container.image, ":latest")
          msg := sprintf("container %v in pod %v uses forbidden image tag latest", [container.name, input.review.object.metadata.name])
        }

        violation[{
          "msg": msg,
          "details": {"container": container.name, "image": container.image}
        }] {
          container := input.review.object.spec.initContainers[_]
          endswith(container.image, ":latest")
          msg := sprintf("initContainer %v in pod %v uses forbidden image tag latest", [container.name, input.review.object.metadata.name])
        }
```

Apply it:

```powershell
kubectl apply -f - <<'EOF'
[...contents above...]
EOF
```

Then create a `Constraint` to enforce it:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sForbidLatest
metadata:
  name: deny-latest-image
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
```
```

Apply the constraint:

```powershell
kubectl apply -f - <<'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sForbidLatest
metadata:
  name: deny-latest-image
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
EOF
```

### Example 2: Require labels on namespaces or workloads

This example ensures that every pod has a required label before it can be created.

```yaml
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        violation[{
          "msg": msg,
          "details": {"missing_labels": missing}
        }] {
          required := {label | label := input.parameters.labels[_]}
          missing := required - object_labels
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }

        object_labels := input.review.object.metadata.labels
        object_labels == null {
          object_labels := {}
        }
```

Constraint:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: require-team-label
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    labels:
      - team
      - application
```
```

### Apply and verify configuration

```powershell
kubectl apply -f k8s-required-labels-template.yaml
kubectl apply -f require-team-label-constraint.yaml
kubectl get constrainttemplates
kubectl get constraints
kubectl describe constraint deny-latest-image
```

## Test policy enforcement

Create a test pod that violates the policy:

```powershell
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-latest-image
spec:
  containers:
    - name: nginx
      image: nginx:latest
EOF
```

The request should be rejected if Gatekeeper is enforcing the constraint.

For a valid pod, use an explicit non-latest tag:

```powershell
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nonlatest-image
spec:
  containers:
    - name: nginx
      image: nginx:1.26.2
EOF
```

## Audit mode and remediation

Gatekeeper supports audits of existing resources:

```powershell
kubectl get auditreport -n gatekeeper-system
kubectl describe auditreport <audit-report-name>
```

To run a manual audit of a constraint, use:

```powershell
kubectl get constrainttemplates
kubectl get constraints
```

If Gatekeeper detects violations in existing resources, update those resources to comply or disable the constraint until remediation is complete.

## Upgrade and maintenance

- Keep Gatekeeper upgraded to a supported version. The `release-3.15` branch is current as of this README, but always check the Gatekeeper GitHub release page.
- For Helm installs, upgrade with:

```powershell
helm repo update
helm upgrade gatekeeper gatekeeper/gatekeeper --namespace gatekeeper-system
```

- For manifest installs, reapply the new release manifest:

```powershell
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml
```

- Monitor Gatekeeper logs:

```powershell
kubectl logs -l app=gatekeeper-controller-manager -n gatekeeper-system
```

## Useful commands

```powershell
kubectl get pods,deployments,services -n gatekeeper-system
kubectl get constrainttemplates
kubectl get constraints --all-namespaces
kubectl describe constraint <constraint-name>
kubectl get auditreports -n gatekeeper-system
kubectl logs -n gatekeeper-system -l app=gatekeeper-controller-manager
```

## Notes

- Gatekeeper enforces policies at admission time, so invalid manifests are rejected before they are persisted.
- Use `dry-run` mode for early validation if you want to test constraints without blocking creation.
- For production AKS, combine Gatekeeper with other security controls such as Azure Policy, Pod Security Standards, and Azure Defender for Kubernetes.
