# Tanzu Mission Control - Self Managed - install notes



## PreReqs
1. K8s v1.26+
2. Three worker nodes each with 4CPU & 8GB RAM
3. Cert-Manager 1.10.2 (Docs say this specific version is needed although it's unsupported)
```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.2/cert-manager.yaml
```

  If you have a Split-brain DNS and cluster default resolvers do not resolve public DNS, install cert-manager so that it uses ONLY external resolvers:
```
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.10.2 \
  --set installCRDs=true  \
  --set 'extraArgs={--dns01-recursive-nameservers-only,--dns01-recursive-nameservers=8.8.8.8:53\,1.1.1.1:53}'
```
4. Kapp-controller (included in recent TKRs in vSphere8 - do not install unless needed)
```
kubectl apply -f https://github.com/carvel-dev/kapp-controller/releases/latest/download/release.yml --dry=run=client
```
4. Bootstrap ubuntu VM with access to local harbor and Internet
5. DNS server/forwarder that can handle wildcards.
  You'll need to be able to add the following:
    a. CNAME for tmc.mydomain.com
    b. wildcard for *.tmc.mydomain.com
    c. wildcard for *.s3.tmc.mydomain.com


## GOTCHAS... so far.

1. Make sure the minio password is MORE THAN 8 characters
2. Make sure that the idpGroupRoles names exactly match the CN of groups in ActiveDiretory and are found
   under the groupBaseDN
3. Removing does not clean up well.  It leaves behind not only pvc and pods, but also secrets that contain certs, etc.  As a result, reinstalls get mixed certifcates and unexpected behavior.  If removing to redeploy, I suggest deleting the package, the redis pvc and ten the entire tmc-local namespace
4. Using a self-signed cert is a problem.  k8s clusters will not trust the cert to install anything from tmc until you add the CA to the trust.  Updated notes for Cloudflare DNS with ACME ClusterIssuer
5. Not sure why the LE Cert was not fully trusted, but I had to add its root cert to trusted CAs


# Objective:
Install Tanzu Mission Control - Self Managed v1.4.0 onto a TKGS cluster
Using a local harbor instance, local Active Directory
For now, using self-signed certificates



## Preparation
1. In Harbor, create a project. I named mine "tmc-sm"
2. Download the Tanzu Mission Control Self Managed v1.4.0 Tar file:  6.11GB
  https://support.broadcom.com/group/ecx/productfiles?subFamily=VMware%20Tanzu%20Mission%20Control%20(Self-Managed)&displayGroup=Product%20Downloads&release=1.4.0&os=&servicePk=208628&language=EN
3. SSH into ubuntu bootstrap VM, confirm it can curl to local harbor
4. In bootstrap VM Create a folder and download tmc-sm tar package to it.  May have to download it from a browser and scp the tar file to the ubuntu VM
5. Still on bootstrap VM, extract the tarfile into a folder:
  ```
  tar -xvf tmc_self_managed_1.4.0.tar -C ./tanzumc
  ```
6. Run this command to push the extracted images to harbor repo
  ```
  tanzumc/tmc-sm push-images harbor --project harbor.lab.brianragazzi.com/tmc-sm --username harboradmin@ragazzilab.com --password P@ssW0rd
  ```
7. Docs say to the review the pushed-package-repository.json file that was created, but you already know the values in it: repo-path and version



## Create and configure namespace:
```
kubectl create namespace tmc-local
kubectl label ns tmc-local pod-security.kubernetes.io/enforce=privileged
```

## add repo
```
tanzu package repository add tanzu-mission-control-packages --url "harbor.lab.brianragazzi.com/tmc-sm/package-repository:1.4.0" --namespace tmc-local
```

## get values schema
```
tanzu package available get "tmc.tanzu.vmware.com/1.4.0" --namespace tmc-local --values-schema
```

## Create Certificates - Self-Signed ClusterIssuer
  1. Check, update & run the ./self-signed-certs/create-ca-cert.sh script to produce the ca.key and tmcsm-ca.crt files
  2. Run this to create the secret in the cert-manager namespace:
```
kubectl create secret tls local-ca --key ./self-signed-certs/ca.key --cert ./self-signed-certs/tmcsm-ca.crt -n cert-manager
```
  3. Apply the ./self-signed-certs/local-issuer.yaml to the cert-manager namespace
```
kubectl apply -f ./self-signed-certs/local-issuer.yaml
```

## Create CloudFlare ClusterIssuer
1. Obtain an API Key from your cloudflare account, grant it access to edit the domain
2. Create a secret in the cert-manager namespace for your cloudflare api key
```
kubectl create secret generic -n cert-manager cloudflare-api-token --from-literal=api-token=ABC123
```
3. Create clusterissuer (adjust email address, etc first)
```
kubectl apply -n cert-manager -f ./cloudflare/clusterissuer.yaml
```
4. Create a test certificate to validate that the clusterissuer is working as expected (adjust FQDN first)

  Remember, cloudflare webhook in cert-manager must be able to validate the PUBLIC DNS record exists, so if cert-manager is using internal DNS servers, that may not work until you configure cert-manager with recursive nameservers
```
kubectl apply -n default -f ./cloudflare/testcert.com
kubectl get certificate -n default
```


## Install! - This will take about 15 mins
```
tanzu package install tanzu-mission-control -p "tmc.tanzu.vmware.com" --version "1.4.0" --values-file ./values.yaml --namespace tmc-local
```
### validate
```
tanzu package installed list -n tmc-local
```


## Update:
```
tanzu package installed update tanzu-mission-control --values-file ./values.yaml -n tmc-local
```

## Remove because you missed a step:
```
tanzu package installed delete -n tmc-local tanzu-mission-control
```
  ### This does not remove all the things, manually remove the following
  1. pvc for redis pod
  2. all secrets in tmc-local ns
  3. suggest deleting and recreating the namespace entirely


# Post-Install

## tamzu plugins
```
tanzu plugin upload-bundle --tar tanzumc/tanzu-cli-plugins/tmc.tar.gz --to-repo harbor.lab.brianragazzi.com/tmc-sm
tanzu plugin source update default -u harbor.lab.brianragazzi.com/tmc-sm/plugin-inventory:latest
```

## Tanzu Standard Package Repo - This takes about 20 minutes and pushes about 16 GB to harbor
```
export IMGPKG_REGISTRY_HOSTNAME_0=harbor.lab.brianragazzi.com
export IMGPKG_REGISTRY_USERNAME_0=harboradmin@ragazzilab.com
export IMGPKG_REGISTRY_PASSWORD_0=P@ssW0rd
imgpkg copy \
-b extensions.aws-usw2.tmc.cloud.vmware.com/packages/standard/repo:v2024.8.2 \
--to-repo harbor.lab.brianragazzi.com/tmc-sm/498533941640.dkr.ecr.us-west-2.amazonaws.com/packages/standard/repo
```
### Istio images - quick, small
```
imgpkg copy \
-b extensions.aws-usw2.tmc.cloud.vmware.com/packages/istio-oss-packages:1.22.0-tanzu.2 \
--to-repo harbor.lab.brianragazzi.com/tmc-sm/packages/istio-oss-packages
```

### original/default
```
imgpkg copy \
-b projects.registry.vmware.com/tkg/packages/standard/repo:v2024.2.1_tmc.1 \
--to-repo harbor.lab.brianragazzi.com/tmc-sm/498533941640.dkr.ecr.us-west-2.amazonaws.com/packages/standard/repo
```

### Updated repo
```
imgpkg copy \
-b projects.registry.vmware.com/tkg/packages/standard/repo:v2024.5.16 \
--to-repo harbor.lab.brianragazzi.com/tanzu-standard/repo
```


## Sonobuoy inspection images - this takes about 30 minutes
1. edit inspection_images.sh, set top few variables
2. SCP to an ubuntu VM with docker that can reach harbor and internet
3. Run inspection_images.sh on the ubuntu VM



## Registering a vSphere-with-Tanzu Supervisor Cluster **IMPORTANT AND POORLY DOCUMENTED**
1. Read this:  https://docs.vmware.com/en/VMware-vSphere/8.0/vsphere-with-tanzu-tkg/GUID-88D350BF-B439-4168-9856-E67081CDB623.html
2. Login to and switch context to the supervisor cluster
3. Get a list of Namespaces, find the one that looks like 'svc-tmc-c######'
4. Create an AgentConfig, see ./vSphere-With-Tanzu/agent-config.yaml
```
kubectl create -n svc-tmc-c###### -f ./vSphere-With-Tanzu/agent-config.yaml
```
5. Now, you can attempt to register the supervisor cluster through TMC UI, obtain the registration URL
6. Update, then apply the agentinstall-register.yaml
```
kubectl create -n svc-tmc-c###### -f ./vSphere-With-Tanzu/agentinstall-register.yaml
```


## Helpful Links
Links: https://vstellar.com/2023/08/tanzu-mission-control-self-managed-part-4-install-cert-manager-and-cluster-issuer-for-tls-certificates/
