# Shared ReadWriteMany storage with Amazon FSx for NetApp ONTAP

This readme walks through using Amazon FSx for NetApp ONTAP to provide `ReadWriteMany` storage to the NIM inferencing pods, enabling multiple pods to share the same persistent volume claim. It builds on the existing workflows found within this directory, but does not replace them.

## Deployment

### Existing workflows

If you're not already, change into the `1.infrastructure` directory:

```text
cd 1.infrastructure
```

Deploy the VPC via CloudFormation and the `vpc-cf-example.yaml` template:

```text
aws cloudformation create-stack --stack-name awsome-inference-vpc \
    --template-body file://0_setup_vpc/vpc-cf-example.yaml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=awsome-inference
```

Wait for the deployment to complete:

```text
$ aws cloudformation describe-stacks --stack-name awsome-inference-vpc | jq '.Stacks[].StackStatus'
"CREATE_COMPLETE"
```

Gather the IDs of the deployed VPC resources:

```text
aws cloudformation describe-stacks --stack-name awsome-inference-vpc
```

Update the `nims-cluster-config-example.yaml` file with these IDs, per [the blog](https://aws.amazon.com/blogs/hpc/deploying-generative-ai-applications-with-nvidia-nims-on-amazon-eks/).

Deploy the EKS cluster:

```text
eksctl create cluster -f 1_setup_cluster/nims-cluster-config-example.yaml
```

Once the EKS cluster is deployed, you're ready to move on to the FSx deployment.

### Amazon FSx for NetApp ONTAP Deployment

Gather necessary variables so FSx can be deployed in the newly created VPC:

```text
VPC=$(aws cloudformation describe-stacks --stack-name awsome-inference-vpc | \
    jq '.Stacks[].Outputs[] | select(.OutputKey == "VPC") | .OutputValue')
VpcCIDR=$(aws cloudformation describe-stacks --stack-name awsome-inference-vpc | \
    jq '.Stacks[].Parameters[] | select(.ParameterKey == "VpcCIDR") | .ParameterValue')
PrivateSubnets=$(aws cloudformation describe-stacks --stack-name awsome-inference-vpc | \
    jq '.Stacks[].Outputs[] | select(.OutputKey == "PrivateSubnets") | .OutputValue')
PrivateRouteTables=$(aws ec2 describe-route-tables --filters \
    Name=association.subnet-id,Values=$(echo $PrivateSubnets | tr -d '"') | \
    jq '[.RouteTables[].RouteTableId] | join(",")')
```

Deploy Amazon FSx for NetApp ONTAP via CloudFormation:

```text
aws cloudformation create-stack --stack-name awsome-inference-fsx --capabilities CAPABILITY_NAMED_IAM \
    --template-body file://1_setup_cluster/fsx-netapp-ontap-example.yaml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=awsome-inference \
                 ParameterKey=PrivateSubnets,ParameterValue=$PrivateSubnets \
                 ParameterKey=PrivateRouteTables,ParameterValue=$PrivateRouteTables \
                 ParameterKey=VPC,ParameterValue=$VPC ParameterKey=VpcCIDR,ParameterValue=$VpcCIDR
```

Wait for the deployment to complete:

```text
$ aws cloudformation describe-stacks --stack-name awsome-inference-fsx | jq '.Stacks[].StackStatus'
"CREATE_COMPLETE"
```

### NetApp Trident Installation and Configuration

Set the Trident IAM Policy deployed in the previous section to a variable:

```text
TridentIamPolicy=$(aws cloudformation describe-stacks --stack-name awsome-inference-fsx | \
    jq -r '.Stacks[].Outputs[] | select(.OutputKey == "TridentIamPolicy") | .OutputValue')
```

Create the Trident IAM Role:

```text
eksctl create iamserviceaccount --name trident-controller --namespace trident \
    --cluster nims-inference-cluster --role-name AmazonEKS_FSxN_Trident_awsome-inference \
    --role-only --attach-policy-arn $TridentIamPolicy --approve
```

Set the Trident IAM Role ARN to a variable:

```text
RoleARN=$(aws iam get-role --role-name AmazonEKS_FSxN_Trident_awsome-inference | jq -r '.Role.Arn')
```

Update the placeholder Role ARN with the actual value in the `trident-configuration-values.json` file:

```text
sed -i '' "s|PLACEHOLDER_ROLE_ARN|$RoleARN|g" 1_setup_cluster/trident-configuration-values.json
```

Install the Trident EKS add-on, referencing the `trident-configuration-values.json` file:

```text
aws eks create-addon --cluster-name nims-inference-cluster --addon-name netapp_trident-operator \
    --addon-version v24.6.1-eksbuild.1 \
    --configuration-values 'file://1_setup_cluster/trident-configuration-values.json'
```

Wait a few minutes, and verify that 6/6 controller pods are in a running state:

```text
$ kubectl -n trident get pods
NAME                                  READY   STATUS    RESTARTS   AGE
trident-controller-5776d77fd7-l55zb   6/6     Running   0          3m6s
trident-node-linux-nl4tw              2/2     Running   0          3m5s
trident-node-linux-xlgvc              2/2     Running   0          3m5s
trident-operator-b994468f7-h9bng      1/1     Running   0          3m29s
```

Set several variables from the FSx deployment:

```text
FSxSVMName=$(aws cloudformation describe-stacks --stack-name awsome-inference-fsx | \
    jq -r '.Stacks[].Parameters[] | select(.ParameterKey == "FSxSVMName") | .ParameterValue')
FSxFsId=$(aws cloudformation describe-stacks --stack-name awsome-inference-fsx | \
    jq -r '.Stacks[].Outputs[] | select(.OutputKey == "FSxFsId") | .OutputValue')
FsxSvmPasswordArn=$(aws cloudformation describe-stacks --stack-name awsome-inference-fsx | \
    jq -r '.Stacks[].Outputs[] | select(.OutputKey == "FsxSvmPasswordArn") | .OutputValue')
```

Update the placeholder values in `trident-backend-sc-setup.sh`:

```text
sed -i '' "s|PLACEHOLDER_SVM_NAME|$FSxSVMName|g" 1_setup_cluster/trident-backend-sc-setup.sh
sed -i '' "s|PLACEHOLDER_FSXFS_ID|$FSxFsId|g" 1_setup_cluster/trident-backend-sc-setup.sh
sed -i '' "s|PLACEHOLDER_SECRET_ARN|$FsxSvmPasswordArn|g" 1_setup_cluster/trident-backend-sc-setup.sh
```

Run the `trident-backend-sc-setup.sh` script to install the Trident backends and storage classes:

```text
sh 1_setup_cluster/trident-backend-sc-setup.sh
```

After a few minutes, ensure the backends and storage classes have been created properly:

```text
$ kubectl -n trident get tbc
NAME                    BACKEND NAME            BACKEND UUID                           PHASE   STATUS
backend-fsx-ontap-nas   backend-fsx-ontap-nas   06471c1b-e14b-41e1-85b1-9c08e4e05b0e   Bound   Success
backend-fsx-ontap-san   backend-fsx-ontap-san   05ab1389-54bf-4dcb-b2a0-f1259851f7de   Bound   Success
$ kubectl get sc
NAME                        PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
fsx-netapp-block            csi.trident.netapp.io   Delete          Immediate              true                   2m4s
fsx-netapp-file (default)   csi.trident.netapp.io   Delete          Immediate              true                   2m3s
gp2                         kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   false                  35m
```

### NIM Deployment

Ensure your `NGC_CLI_API_KEY` has been set as an environment variable:

```text
export NGC_CLI_API_KEY="key from ngc"
```

Change into the `2.projects` directory:

```text
cd ../2.projects
```

Deploy NIM with the following Helm command:

```text
helm install -n nim --create-namespace my-nim nims-inference/nim-deploy/helm/nim-llm/ \
    --set model.ngcAPIKey=$NGC_CLI_API_KEY --set replicaCount=2 \
    --set persistence.enabled=true --set persistence.accessMode=ReadWriteMany
```

Note we're setting the replica count to 2, enabling persistence, and setting the persistent volume claim accessMode to `ReadWriteMany`. We do not need to specify the `fsx-netapp-file` storage class, as it's set as the cluster default.

After a few minutes, you should see the NIM pods go into a running state:

```text
NAME           READY   STATUS    RESTARTS   AGE
pod/my-nim-0   1/1     Running   0          6m24s
pod/my-nim-1   1/1     Running   0          6m23s

NAME                     TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/my-nim-nim-llm   ClusterIP   172.20.22.115   <none>        8000/TCP   6m24s

NAME                      READY   AGE
statefulset.apps/my-nim   2/2     6m24s

NAME                                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS      VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/my-nim-nim-llm   Bound    pvc-361e666d-c043-4897-be8d-3c7a94dc81dd   50Gi       RWX            fsx-netapp-file   <unset>                 6m24s
```

Port forward the service:

```text
kubectl -n nim port-forward service/my-nim-nim-llm 8000:8000
```

Run a test inference via curl:

```text
curl -X 'POST' \
'http://localhost:8000/v1/chat/completions' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "messages": [
    {
      "content": "You are a polite and respectful chatbot helping people plan a vacation.",
      "role": "system"
    },
    {
      "content": "What should I do for a 4 day vacation in Spain?",
      "role": "user"
    }
  ],
  "model": "meta/llama3-8b-instruct",
  "max_tokens": 32,
  "top_p": 1,
  "n": 1,
  "stream": false,
  "stop": "\n",
  "frequency_penalty": 0.0
}'
```

You should receive a response like this if everything is working as expected:

```text
{"id":"cmpl-b1fd37ee8cf145b6829028e898b1de96","object":"chat.completion","created":1732213550,"model":"meta/llama3-8b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"Spain is a wonderful destination! With four days, you can easily explore one or two regions, or focus on a particular city. Here are a few suggestions:\n\n"},"logprobs":null,"finish_reason":"length","stop_reason":null}],"usage":{"prompt_tokens":42,"total_tokens":74,"completion_tokens":32}}
```
