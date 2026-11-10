# CO3141 - Hướng dẫn triển khai từ đầu đến cuối cho nhóm 3buanhan

## 0. Mục tiêu và cách làm

Nhóm triển khai **một workload dùng chung, một VPC, một ECS Cluster chạy trên EC2**, rồi phát triển ba module trên cùng nền tảng:

| Người phụ trách | Phần chính | Đầu ra cần chứng minh |
|---|---|---|
| Trần Quang Duy | Nền tảng + Resource Management | VPC/ECS/EC2; tagging; inventory; Auto Scaling; rightsizing; idle-resource review |
| Huỳnh Hải Nguyên | Scheduling | ECS Binpack/Spread; AWS Batch; EventBridge Scheduler |
| Đoàn Anh Kiệt | Orchestration | DynamoDB idempotency; Lambda; Step Functions; ECS RunTask; Retry/Catch |
| Cả ba | Tích hợp và báo cáo | Dashboard, số liệu, bảng so sánh, kiến trúc đề xuất, demo, cleanup |

**Không phải mỗi người dựng một AWS account hay một cụm hạ tầng riêng.** Duy dựng nền tảng chung trước. Nguyên và Kiệt phát triển module trên những tài nguyên chung đó. Mỗi module phải được tích hợp ngay khi có bản chạy được, không chờ đến tuần cuối.

Đồ án gốc yêu cầu nghiên cứu ba trụ cột Resource Management, Scheduling, Orchestration; đối chiếu cơ chế AWS và đề xuất cân bằng chi phí - hiệu năng - độ tin cậy. Kế hoạch 8 tuần là giả định tổ chức công việc, không phải deadline được nêu trong đề bài.

### Kiến trúc mục tiêu

Một Docker image chứa hai tiến trình: API FastAPI (`app.py`) và worker (`worker.py`). API dùng để tạo tải cho thí nghiệm Resource Management. Worker được gọi bởi ECS RunTask, AWS Batch, EventBridge Scheduler và Step Functions. Như vậy nhóm có một workload thống nhất để so sánh.

**Lựa chọn kỹ thuật quan trọng:** thí nghiệm ECS task placement Binpack/Spread phải chạy trên ECS EC2. AWS nêu rõ placement strategies/constraints không được hỗ trợ với Fargate; ECS EC2 hỗ trợ các chiến lược này. Không dùng Fargate cho bài so sánh này. (Nguồn: AWS ECS task placement docs ở cuối tài liệu.)

---

## Stage 0 - Bảo vệ tài khoản AWS và giới hạn chi phí

Thực hiện trước khi tạo bất kỳ tài nguyên tính phí nào.

1. Chọn một người quản lý tài khoản AWS. Không chia sẻ mật khẩu root hoặc root access key. Bật MFA cho root và dùng IAM Identity Center/role hoặc danh tính riêng cho từng thành viên.
2. Vào **Billing and Cost Management** để xem loại tài khoản, credit còn lại và ngày hết hạn credit. Không giả định tài khoản nào cũng có Free Tier 12 tháng.
3. Tạo AWS Budget cho dự án. Ví dụ đặt ngưỡng cảnh báo nội bộ 10 USD/tháng hoặc một mức thấp hơn do nhóm tự thống nhất; thêm cảnh báo Actual và Forecast ở 50%, 80%, 100%. Đây chỉ là cảnh báo, **không phải hard spending cap** và dữ liệu billing có thể trễ.
4. Chọn Region `ap-southeast-1` (Singapore) và giữ tất cả tài nguyên trong Region đó.
5. Quy ước tag: `Project=CO3141`, `Team=3buanhan`, `Environment=lab`, `Owner=Duy|Nguyen|Kiet`, `Module=foundation|resource|scheduling|orchestration`.
6. Không commit credential, `.aws`, access key, `.env` hoặc dữ liệu nhạy cảm lên GitHub.

Môi trường lab trong starter kit dùng hai public subnet và EC2 host có public IPv4 để tránh NAT Gateway. Security Group không mở SSH và ALB chỉ nhận HTTP từ IP public của nhóm. Đây là cách dựng lab ngắn hạn, **không phải kiến trúc production**. Xóa tài nguyên sau khi thử nghiệm.

---

## Stage 1 - Cài công cụ và tạo repository chung

### 1.1 Công cụ cần có trên cả ba máy

- Git.
- Docker Desktop, bật Linux containers.
- AWS CLI v2.
- Python 3.12 trở lên (local test; Docker image đã dùng Python 3.12).
- VS Code hoặc editor tương đương.

### 1.2 Tạo GitHub repository

1. Duy tạo repository private, ví dụ `co3141-resource-scheduling-orchestration`.
2. Thêm Nguyên và Kiệt làm collaborator.
3. Duy đưa toàn bộ thư mục starter kit vào repository, commit nhánh `main`.
4. Mỗi thành viên tạo branch riêng:

```powershell
git checkout -b feature/resource-management
git checkout -b feature/scheduling
git checkout -b feature/orchestration
```

Mỗi người chỉ tạo branch tương ứng từ `main`, không dùng cả ba lệnh liên tiếp trên cùng một nhánh. Branch làm việc phải được push lên GitHub và tạo Pull Request về `main` sau khi chạy thử.

Cấu trúc thư mục:

```text
co3141_group_runbook/
  cloudformation/       # các template triển khai AWS
  docs/                 # runbook và sơ đồ
  lambdas/              # mã nguồn Lambda để đọc/tham khảo
  orchestration/        # Step Functions ASL
  overrides/            # ECS container overrides
  scripts/              # PowerShell scripts
  workload/             # FastAPI + worker + Dockerfile
  README.md
```

### 1.3 Cấu hình AWS CLI

Nếu nhóm dùng IAM user/profile:

```powershell
aws configure --profile co3141
aws sts get-caller-identity --profile co3141
```

Nếu dùng IAM Identity Center, chạy `aws configure sso --profile co3141` rồi đăng nhập bằng `aws sso login --profile co3141`.

**Kiểm tra Account ID và Region trước khi deploy.** Không dùng profile cá nhân của người khác nếu chưa được chủ tài khoản cấp quyền.

---

## Stage 2 - Chạy workload ở local trước

Mục đích: phát hiện lỗi Python/API trước khi đưa code lên AWS.

Mở PowerShell tại thư mục project:

```powershell
cd workload
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app:app --reload --port 8000
```

Mở PowerShell thứ hai:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health
Invoke-RestMethod 'http://127.0.0.1:8000/work?seconds=2'
python .\worker.py --seconds 3
python .\worker.py --seconds 1 --fail
```

Kết quả mong đợi:

- `/health` trả về `status=ok`.
- `/work` trả elapsed time, số vòng lặp và checksum.
- Worker bình thường in `START` rồi `FINISH` và thoát mã 0.
- Worker với `--fail` in thông báo lỗi giả lập và thoát mã khác 0.

Endpoint `/work` cố ý dùng CPU để nhóm tạo tải. Không dùng API này như một dịch vụ production và không mở public cho toàn Internet.

---

## Stage 3 - Dựng data foundation và đẩy Docker image

### 3.1 Những gì template tạo

`cloudformation/data-foundation.yaml` tạo:

- ECR repository: lưu image dùng chung.
- S3 bucket: private, mã hóa, dùng để lưu kết quả/thí nghiệm nếu nhóm cần.
- DynamoDB table: partition key `idempotencyKey` cho phần Orchestration.
- CloudWatch Log Group: log của API/worker, retention 7 ngày.

### 3.2 Tạo toàn bộ hạ tầng lõi bằng một lệnh

Từ thư mục gốc project, lấy IP public hiện tại:

```powershell
$myIp = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
$cidr = "$myIp/32"
$cidr
```

Sau đó deploy:

```powershell
.\scripts\deploy-project.ps1 `
  -AllowedIngressCidr $cidr `
  -Profile co3141 `
  -Region ap-southeast-1 `
  -ImageTag v1 `
  -InstanceType t3.small
```

Script thực hiện tuần tự:

1. Validate các CloudFormation template lõi.
2. Kiểm tra AWS identity theo profile `co3141`.
3. Tạo ECR, S3, DynamoDB và Log Group.
4. Build Docker image và push lên ECR với tag bất biến `v1`.
5. Tạo VPC, hai public subnet, ECS Cluster, EC2 Auto Scaling Group, ECS Capacity Provider và ALB.
6. Tạo API/worker task definition và ECS API service.
7. Tạo Lambda idempotency và Step Functions state machine.

Nếu nhóm thay code, dùng tag mới `v2`, `v3`... vì ECR repository đang đặt `IMMUTABLE`; không push đè `v1`.

### 3.3 Xem output sau deploy

```powershell
aws cloudformation describe-stacks `
  --stack-name co3141-shared-infra `
  --region ap-southeast-1 --profile co3141 `
  --query "Stacks[0].Outputs" --output table

aws cloudformation describe-stacks `
  --stack-name co3141-ecs-service `
  --region ap-southeast-1 --profile co3141 `
  --query "Stacks[0].Outputs" --output table

aws cloudformation describe-stacks `
  --stack-name co3141-orchestration `
  --region ap-southeast-1 --profile co3141 `
  --query "Stacks[0].Outputs" --output table
```

Ghi lại các output: `AlbDnsName`, `EcsClusterName`, `EcsCapacityProviderName`, `EcsAutoScalingGroupName`, `WorkerTaskDefinitionArn`, `StateMachineArn`, `ResultsBucketName`.

---

## Stage 4 - Duy: kiểm tra nền tảng và Resource Management

### 4.1 Kiểm tra API trên ECS

Lấy ALB DNS từ output `AlbDnsName`, sau đó:

```powershell
$baseUrl = "http://<ALB-DNS-NAME>"
.\scripts\test-api.ps1 -BaseUrl $baseUrl
```

Mong đợi `/health` trả `ok`. Nếu không truy cập được, kiểm tra theo thứ tự:

1. IP public có đúng `AllowedIngressCidr` không.
2. ALB listener đang ở port 80.
3. ECS API service có desired/running task không.
4. Container instance đã đăng ký vào cluster chưa.
5. Target Group có healthy target không.
6. CloudWatch log có traceback hoặc lỗi pull ECR không.

### 4.2 Hiểu rõ hai lớp Auto Scaling

| Thành phần | Scale cái gì? | Theo dõi ở đâu? |
|---|---|---|
| ECS Service Auto Scaling | Số lượng API task/container | ECS Service desired/running count; CloudWatch CPUUtilization |
| EC2 Auto Scaling Group / ECS Capacity Provider | Số lượng EC2 host cung cấp năng lực chạy task | EC2 ASG desired/in-service instances; ECS container instances |

Không được kết luận “task tăng tức là EC2 tăng”. Một host có thể chạy nhiều task nếu CPU/RAM còn đủ.

### 4.3 Tạo tải cho API

```powershell
.\scripts\load-api.ps1 `
  -BaseUrl $baseUrl `
  -Workers 8 `
  -RequestsPerWorker 3 `
  -Seconds 5
```

Mở ECS Console và CloudWatch trong lúc chạy. Ghi lại:

- thời điểm bắt đầu/kết thúc tải;
- số request thành công/thất bại;
- CPU và memory utilization của ECS service;
- desired task count và running task count;
- ASG desired capacity và số EC2 instance InService;
- thời gian scale-out và scale-in quan sát được.

Target tracking CPU được cấu hình ban đầu khoảng 55%, min 1 task, max 3 task. Đây chỉ là giá trị thử nghiệm; ghi kết quả thực tế, không khẳng định chắc chắn hệ thống sẽ scale sau một số giây cố định.

### 4.4 Thí nghiệm Resource Management

Duy ghi lại ít nhất bốn bảng:

**A. Resource inventory**

```powershell
aws resourcegroupstaggingapi get-resources `
  --tag-filters Key=Project,Values=CO3141 `
  --region ap-southeast-1 --profile co3141 `
  --output table
```

**B. EC2/ASG hiện tại**

```powershell
aws autoscaling describe-auto-scaling-groups `
  --auto-scaling-group-names co3141-ecs-asg `
  --region ap-southeast-1 --profile co3141 `
  --query "AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Instances:Instances[*].{Id:InstanceId,State:LifecycleState,Health:HealthStatus}}" `
  --output json
```

**C. Rightsizing**

| Trạng thái | Task CPU request | Task memory request | CPU observed | Memory observed | Đề xuất |
|---|---:|---:|---:|---:|---|
| Idle | 256 | 512 MiB | nhóm điền | nhóm điền | nhóm điền |
| Normal | 256 | 512 MiB | nhóm điền | nhóm điền | nhóm điền |
| Load | 256 | 512 MiB | nhóm điền | nhóm điền | nhóm điền |

**D. Idle resources**

Kiểm tra EBS volume không gắn instance, snapshot cũ, EC2 host nhàn rỗi, ALB không còn dùng, Elastic IP không gắn, ECR image cũ. Không xóa tài nguyên nếu chưa xác nhận chủ sở hữu và mục đích.

### 4.5 Cost analysis

- Mở Cost Explorer, lọc theo Region/service và khoảng ngày của thí nghiệm.
- Kích hoạt user-defined cost allocation tags `Project` và `Team` trong Billing.
- Tag mới có thể cần thời gian xuất hiện trong danh sách activation; không chờ đến tuần cuối mới bật.
- Tách chi phí EC2, ELB, ECR, S3, CloudWatch, Lambda, Step Functions, DynamoDB và Batch nếu dữ liệu có.
- Dùng bucket S3 private được tạo ở Stage 3 để lưu bản CSV số liệu và ảnh bằng chứng cuối cùng. Lấy bucket name và upload ví dụ:

```powershell
$bucket = aws cloudformation describe-stacks --stack-name co3141-data-foundation --region ap-southeast-1 --profile co3141 --query "Stacks[0].Outputs[?OutputKey=='ResultsBucketName'].OutputValue" --output text
New-Item -ItemType Directory -Force .\results | Out-Null
@"
experiment,run,notes
resource-management,baseline,replace with measured results
scheduling,binpack-spread,replace with measured results
orchestration,retry-catch,replace with measured results
"@ | Set-Content .\results\summary.csv -Encoding utf8
aws s3 cp .\results\summary.csv "s3://$bucket/evidence/summary.csv" --region ap-southeast-1 --profile co3141
aws s3 ls "s3://$bucket/evidence/" --region ap-southeast-1 --profile co3141
```

Thay nội dung mẫu bằng số liệu thật trước khi nộp báo cáo. Không bật public access.
- Ngân sách chỉ cảnh báo, không tự động dừng mọi dịch vụ.

**Bàn giao của Duy:** architecture nền, CloudFormation nền tảng, inventory, bảng rightsizing, idle-resource list, số liệu scale và bảng chi phí.

---

## Stage 5 - Nguyên: Scheduling

### 5.1 ECS Binpack vs Spread

Trước khi chạy phải có ít nhất **hai ECS EC2 container instances ở trạng thái ACTIVE**. ASG mặc định chỉ có một EC2 instance để giảm chi phí. Tăng lên hai tạm thời. Worker task definition được đặt CPU reservation 256 units và memory 128 MiB; chạy 10 worker sẽ cần tổng cộng 2.560 CPU units, chưa tính API task, nên không thể dồn toàn bộ lên một `t3.small` 2 vCPU. Đây là cách tạo tải placement đủ rõ, không phải một kết quả Binpack/Spread được đảm bảo.

```powershell
aws autoscaling update-auto-scaling-group `
  --auto-scaling-group-name co3141-ecs-asg `
  --min-size 1 --desired-capacity 2 --max-size 2 `
  --region ap-southeast-1 --profile co3141
```

Đợi hai instance `InService` trong Auto Scaling Group và hai ECS container instances `ACTIVE` trong ECS Console.

Thiết lập biến môi trường (chạy trong cùng cửa sổ PowerShell cho cả hai lần test):

```powershell
$env:ECS_CLUSTER = "co3141-cluster"
$env:ECS_WORKER_TASK = "co3141-worker"
$env:ECS_CAPACITY_PROVIDER = "co3141-ec2-capacity"
```

Trước khi bắt đầu, bảo đảm API service đang chỉ chạy một task (đợi scale-in sau thử nghiệm tải nếu trước đó service đã scale lên). Hai host phải ở trạng thái `InService`/`ACTIVE`.

**Lần A - Binpack theo CPU:**

```powershell
.\scripts\run-placement.ps1 -Strategy binpack -Count 10
```

**Lần B - Spread theo instanceId:**

```powershell
.\scripts\run-placement.ps1 -Strategy spread -Count 10
```

Script sẽ tạo 10 worker trong một lần `RunTask`, in task ARN/container instance và ánh xạ sang EC2 instance ID. Worker chạy 120 giây để có đủ thời gian quan sát. Với CPU reservation 256 units/task, Binpack có thể gom nhiều task hơn về host đã có mức sử dụng cao; Spread cố phân bổ đồng đều theo `instanceId`. Ghi số task thực tế trên từng EC2 host. Đợi tất cả task kết thúc trước khi bắt đầu strategy tiếp theo.

**Cách giải thích kết quả:**

- Binpack cố gắng đặt task để giảm CPU/RAM còn dư; thường gom task lên ít host hơn khi đủ sức chứa.
- Spread cố gắng phân bố task đều theo `instanceId`; có thể dùng nhiều host hơn và để lại nhiều tài nguyên dư hơn.
- Placement strategy là best-effort. Kết quả không bắt buộc phải là 7-3 hoặc 5-5. Ghi đúng số liệu quan sát, không tự làm tròn để khớp kỳ vọng.

| Lần chạy | Strategy | Số task | Số EC2 host sử dụng | CPU avg | Memory avg | Pending time | Nhận xét |
|---|---|---:|---:|---:|---:|---:|---|
| A | Binpack / cpu | 10 | điền số liệu | điền | điền | điền | điền |
| B | Spread / instanceId | 10 | điền số liệu | điền | điền | điền | điền |

Sau khi chụp ảnh và ghi số liệu, giảm ASG desired capacity về 1:

```powershell
aws autoscaling update-auto-scaling-group `
  --auto-scaling-group-name co3141-ecs-asg `
  --min-size 1 --desired-capacity 1 --max-size 2 `
  --region ap-southeast-1 --profile co3141
```

### 5.2 AWS Batch

AWS Batch được dựng bằng `cloudformation/batch.yaml`. Compute Environment sử dụng EC2 On-Demand, `MinvCpus=0`, `DesiredvCpus=0`, `MaxvCpus=2`; vì vậy không giữ sẵn EC2 Batch worker khi chưa có job. Khi submit job, Batch có thể khởi tạo EC2 để chạy job; thời gian khởi tạo không tức thời.

Triển khai Batch (sau khi Stage 3 thành công):

```powershell
.\scripts\deploy-batch.ps1 -Profile co3141 -Region ap-southeast-1 -ImageTag v1
```

Chạy một job và chờ kết quả:

```powershell
.\scripts\run-batch.ps1 -Profile co3141 -Region ap-southeast-1 -JobName co3141-demo-01
```

Mở AWS Batch → Jobs, chụp lại các trạng thái và mở CloudWatch Logs để xem `START`/`FINISH`. Ghi lại `jobId`, thời gian chờ RUNNABLE/STARTING, thời gian RUNNING, exit code và statusReason.

Nếu Batch compute environment không chuyển sang `VALID`, kiểm tra subnet, Security Group outbound, instance profile, service-linked role và IAM quyền `iam:CreateServiceLinkedRole`. Không tiếp tục submit job khi environment chưa VALID.

### 5.3 EventBridge Scheduler

Tạo one-time schedule để gọi ECS RunTask đúng một thời điểm. Schedule được cấu hình với timezone `Asia/Ho_Chi_Minh`, target là ECS cluster, capacity provider `co3141-ec2-capacity`, task definition `co3141-worker` và command chạy 15 giây.

Ví dụ tạo lịch chạy sau khoảng 10 phút (đảm bảo máy đang dùng giờ Việt Nam):

```powershell
$at = (Get-Date).AddMinutes(10).ToString("yyyy-MM-ddTHH:mm:ss")
.\scripts\create-schedule.ps1 -ScheduleAt $at -Profile co3141 -Region ap-southeast-1 -Timezone Asia/Ho_Chi_Minh
```

Kiểm tra schedule:

```powershell
aws scheduler get-schedule `
  --name co3141-worker-once `
  --region ap-southeast-1 --profile co3141
```

Đợi đến giờ hẹn, xác minh ECS worker task được tạo và CloudWatch log có `START`/`FINISH`. Sau khi lưu bằng chứng, xóa schedule stack:

```powershell
aws cloudformation delete-stack --stack-name co3141-scheduler --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-scheduler --region ap-southeast-1 --profile co3141
```

Không tạo recurring schedule để bật/tắt EC2 khi chưa có runbook phục hồi. Phần bật/tắt tài nguyên ban đêm là extension, không phải điều kiện bắt buộc của bản đầu.

### 5.4 Kubernetes Scheduler bằng kind (phần mở rộng, không bắt buộc cho core AWS lab)

Bản chính của nhóm dùng ECS EC2; mục này chỉ dành cho trường hợp giảng viên yêu cầu minh họa thêm Kubernetes/EKS scheduler. Không tạo EKS cluster thật chỉ để demo ngắn vì control plane EKS có chi phí riêng. Dùng `kind` để chạy Kubernetes cục bộ, không tuyên bố đây là EKS.

Cài Docker Desktop, `kind` và `kubectl`, sau đó từ thư mục gốc repository:

```powershell
.\scripts\run-kind-demo.ps1
kubectl get nodes -o wide
kubectl get pods -n co3141 -o wide
```

Manifest chạy 6 pod có CPU/memory requests và `topologySpreadConstraints` với `maxSkew: 1` theo hostname. Ghi số pod trên từng worker node và giải thích Kubernetes scheduler đã lọc/scoring node rồi áp dụng topology spread constraint. Đây là minh họa scheduling constraint, **không phải benchmark Binpack/Spread tương đương ECS**.

Sau khi chụp ảnh:

```powershell
.\scripts\cleanup-kind-demo.ps1
```

Nếu giảng viên bắt buộc AWS EKS thật, nhóm cần xác nhận ngân sách/tài khoản trước; không bật EKS control plane liên tục trong lab.

**Bàn giao của Nguyên:** bảng Binpack/Spread, ảnh container placement, Batch job lifecycle/log, Scheduler configuration và bằng chứng task bắt đầu đúng lịch. Nếu làm phần mở rộng, bổ sung ảnh pod placement kind và giải thích topology spread.

---

## Stage 6 - Kiệt: Orchestration

### 6.1 Luồng workflow

```text
StartExecution { jobId, fail }
          |
          v
ClaimJob Lambda -> Conditional PutItem DynamoDB
          |
          v
CheckDuplicate
   | duplicate                  | new job
   v                            v
AlreadyProcessed            RunWorker (ECS RunTask .sync)
                                  |
                            success | failure
                                  |  |
                                  v  v
                           MarkSucceeded / MarkFailed
                                  |
                                  v
                             End / Fail
```

`cloudformation/orchestration.yaml` tạo hai Lambda inline, IAM role tối thiểu, Step Functions Standard state machine và quyền cần thiết để gọi ECS `.sync`. Các file `lambdas/claim_job.py` và `lambdas/mark_job.py` là bản mã nguồn dễ đọc để tham khảo; template hiện tại chứa bản tương đương inline để có thể deploy bằng một lệnh.

### 6.2 Ý nghĩa idempotency

- `ClaimJob` thử ghi `jobId` vào DynamoDB bằng conditional write `attribute_not_exists(idempotencyKey)`.
- Lần đầu: record được tạo với `IN_PROGRESS`, workflow cho phép worker chạy.
- Lần sau dùng lại `jobId`: conditional write bị từ chối, Lambda đọc record cũ và trả `duplicate=true`; worker không chạy lại.
- Worker thành công: `MarkSucceeded` cập nhật `SUCCEEDED`.
- Worker lỗi sau retry: `MarkFailed` cập nhật `FAILED`.

Đây là cơ chế chống submit trùng theo `jobId`, **không phải bảo đảm exactly-once cho mọi side effect**. Nếu worker ghi S3 hoặc gọi dịch vụ ngoài, side effect đó vẫn phải được thiết kế idempotent. Job ID đã có record (kể cả FAILED/IN_PROGRESS) sẽ được coi là đã xử lý; dùng ID mới cho lần demo mới.

### 6.3 Chạy nhánh thành công

Lấy ARN từ stack output:

```powershell
$raw = aws cloudformation describe-stacks --stack-name co3141-orchestration --region ap-southeast-1 --profile co3141 --output json
$smArn = ((($raw | ConvertFrom-Json).Stacks[0].Outputs) | Where-Object OutputKey -eq "StateMachineArn").OutputValue
```

Bắt đầu execution (chú ý input luôn có `fail` dạng chuỗi `"false"` hoặc `"true"`):

```powershell
$start = aws stepfunctions start-execution `
  --state-machine-arn $smArn `
  --name "success-$(Get-Date -Format yyyyMMddHHmmss)" `
  --input '{"jobId":"demo-success-001","fail":"false"}' `
  --region ap-southeast-1 --profile co3141 --output json | ConvertFrom-Json
$start.executionArn
```

Kiểm tra trạng thái:

```powershell
aws stepfunctions describe-execution `
  --execution-arn $start.executionArn `
  --region ap-southeast-1 --profile co3141
```

Mong đợi `SUCCEEDED`. Trong Step Functions Graph, workflow đi qua ClaimJob → CheckDuplicate → RunWorker → MarkSucceeded.

### 6.4 Chứng minh duplicate protection

Tạo execution thứ hai với **cùng `jobId` nhưng tên execution mới**:

```powershell
aws stepfunctions start-execution `
  --state-machine-arn $smArn `
  --name "duplicate-$(Get-Date -Format yyyyMMddHHmmss)" `
  --input '{"jobId":"demo-success-001","fail":"false"}' `
  --region ap-southeast-1 --profile co3141
```

Mong đợi workflow đi vào `AlreadyProcessed`, không tạo worker ECS mới.

### 6.5 Chứng minh Retry/Catch

Worker hỗ trợ biến môi trường `FAIL_MODE`. Tạo job mới với `fail=true`:

```powershell
$failed = aws stepfunctions start-execution `
  --state-machine-arn $smArn `
  --name "failure-$(Get-Date -Format yyyyMMddHHmmss)" `
  --input '{"jobId":"demo-failure-001","fail":"true"}' `
  --region ap-southeast-1 --profile co3141 --output json | ConvertFrom-Json
```

Worker sẽ chủ động thoát mã lỗi. Step Functions thử lại theo cấu hình Retry, sau đó đi Catch → MarkFailed → WorkflowFailed. Trạng thái cuối của execution là `FAILED`, còn DynamoDB record phải có `status=FAILED`. Đây là lỗi giả lập có chủ đích, không phải lỗi do hệ thống thật.

Kiểm tra record:

```powershell
aws dynamodb get-item `
  --table-name co3141-idempotency `
  --key '{"idempotencyKey":{"S":"demo-success-001"}}' `
  --consistent-read --region ap-southeast-1 --profile co3141

aws dynamodb get-item `
  --table-name co3141-idempotency `
  --key '{"idempotencyKey":{"S":"demo-failure-001"}}' `
  --consistent-read --region ap-southeast-1 --profile co3141
```

**Bàn giao của Kiệt:** sơ đồ state machine, ảnh execution success/duplicate/failure, DynamoDB records, log Lambda/worker và giải thích idempotency + Retry/Catch.

---

## Stage 7 - Cả nhóm: Monitoring và thu thập bằng chứng

Tạo CloudWatch Dashboard `CO3141-Team-Dashboard`. Thêm các metric widgets sau (Console → CloudWatch → Dashboards → Create dashboard → Add widget → Metrics):

| Namespace | Metric cần thêm | Dimension lọc |
|---|---|---|
| AWS/ECS | CPUUtilization, MemoryUtilization | ClusterName + ServiceName |
| AWS/ECS | RunningTaskCount, DesiredTaskCount, PendingTaskCount | ClusterName + ServiceName (nếu metric có sẵn ở dimension tương ứng) |
| AWS/EC2 | CPUUtilization | InstanceId của EC2 host trong ASG |
| AWS/ApplicationELB | RequestCount, TargetResponseTime, HealthyHostCount | LoadBalancer + TargetGroup |
| AWS/Lambda | Invocations, Errors, Duration | FunctionName của hai Lambda |
| AWS/States | ExecutionsSucceeded, ExecutionsFailed, ExecutionsTimedOut | StateMachineArn |
| AWS/Batch | SubmittedJobs, RunnableJobs, RunningJobs, SucceededJobs, FailedJobs | JobQueue (trong thời gian thử nghiệm) |

Lưu dashboard thành ảnh. Metric memory của hệ điều hành EC2 không tự có trong EC2 basic metrics; nếu cần memory của host thì phải cài CloudWatch Agent, nếu không chỉ báo cáo ECS task/service memory. Không trộn hai loại metric.

### Evidence checklist

- [ ] Local API `/health`, `/work` và worker.
- [ ] ECR repository có image tag được dùng trong task definition.
- [ ] ECS API service healthy sau ALB.
- [ ] ECS cluster có ít nhất hai EC2 container instances trong placement experiment.
- [ ] Output Binpack và Spread, có map container instance → EC2 instance ID.
- [ ] ECS service CPU/Memory, task desired/running và ASG desired/in-service trước/during/after load.
- [ ] AWS Batch job status + CloudWatch log.
- [ ] EventBridge Scheduler config + ECS task được khởi chạy.
- [ ] Step Functions thành công, duplicate và failure graph.
- [ ] DynamoDB có record `SUCCEEDED` và `FAILED`.
- [ ] CloudWatch Dashboard, Cost Explorer, inventory và idle-resource list.

---

## Stage 8 - Viết báo cáo và chuẩn bị demo

### Báo cáo đề xuất

1. Introduction & reason for choosing the topic.
2. Resource Management: AWS services/mechanisms, lifecycle, experiment setup and results.
3. Scheduling: Binpack vs Spread, AWS Batch, EventBridge Scheduler, trade-offs.
4. Orchestration: state machine, Retry/Catch, idempotency, duplicate/failure test.
5. Five problems and how the three pillars address them.
6. Experiment results and comparison table.
7. Proposed architecture balancing cost, performance and reliability.
8. Limitations, cost notes, conclusion and appendix (IaC, scripts, runbook).

Không điền số liệu giả. Nếu có metric không thu thập được, ghi rõ giới hạn đo và dùng evidence thực tế khác.

### Demo 10-15 phút

| Thời lượng | Người trình bày | Nội dung |
|---|---|---|
| 1 phút | Cả nhóm | Kiến trúc chung và workload |
| 3 phút | Duy | Tags/inventory, tạo tải, ECS Service scaling và EC2 scaling |
| 3 phút | Nguyên | Binpack/Spread, Batch và Scheduler |
| 3 phút | Kiệt | Step Functions success, duplicate, Retry/Catch |
| 2 phút | Cả nhóm | Dashboard, chi phí, trade-off và kiến trúc đề xuất |
| 1-3 phút | Cả nhóm | Q&A, video dự phòng |

Quay video demo dự phòng. Không cần để các tài nguyên AWS chạy liên tục chỉ để có video.

---

## Stage 9 - Cleanup: xóa tài nguyên sau thí nghiệm

Thực hiện theo thứ tự và xác minh từng bước. Không xóa stack nền trước khi xóa các stack phụ thuộc.

### 9.1 Xóa schedule và Batch (nếu đã tạo)

```powershell
aws cloudformation delete-stack --stack-name co3141-scheduler --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-scheduler --region ap-southeast-1 --profile co3141

aws cloudformation delete-stack --stack-name co3141-batch --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-batch --region ap-southeast-1 --profile co3141
```

Chỉ xóa Batch stack sau khi các job đã vào trạng thái terminal `SUCCEEDED` hoặc `FAILED`.

### 9.2 Dừng ECS tasks/service và xóa các stack phụ thuộc

Trước tiên xem task còn chạy:

```powershell
aws ecs list-tasks --cluster co3141-cluster --region ap-southeast-1 --profile co3141
```

Dừng standalone test task còn chạy; sau đó xóa các stack theo thứ tự orchestration → ECS service → shared infra → data foundation:

```powershell
aws cloudformation delete-stack --stack-name co3141-orchestration --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-orchestration --region ap-southeast-1 --profile co3141

aws ecs update-service --cluster co3141-cluster --service co3141-api-service --desired-count 0 --region ap-southeast-1 --profile co3141
aws cloudformation delete-stack --stack-name co3141-ecs-service --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-ecs-service --region ap-southeast-1 --profile co3141

aws cloudformation delete-stack --stack-name co3141-shared-infra --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-shared-infra --region ap-southeast-1 --profile co3141
```

### 9.3 Xóa data foundation

S3 bucket phải trống trước khi xóa stack. Lấy tên bucket từ output `ResultsBucketName`, sau đó. ECR repository đã bật `EmptyOnDelete: true`, nên CloudFormation tự xóa các image khi xóa data foundation:

```powershell
aws s3 rm s3://<RESULTS-BUCKET-NAME> --recursive --region ap-southeast-1 --profile co3141
aws cloudformation delete-stack --stack-name co3141-data-foundation --region ap-southeast-1 --profile co3141
aws cloudformation wait stack-delete-complete --stack-name co3141-data-foundation --region ap-southeast-1 --profile co3141
```

Nếu muốn giữ dữ liệu cho báo cáo, tải kết quả cần thiết về máy trước khi xóa bucket. Kiểm tra CloudFormation stacks không còn `DELETE_FAILED`.

### 9.4 Kiểm tra billing sau cleanup

- Xem EC2 instances, EBS volumes, Load Balancers, Target Groups, public IPv4, VPC endpoints/NAT nếu có, CloudWatch Logs, S3 và Batch compute environments.
- Mở Billing/Cost Explorer kiểm tra các ngày tiếp theo vì billing data có thể trễ.
- Không chỉ dựa vào thông báo “stack deleted”; vẫn phải rà tài nguyên thủ công nếu stack delete lỗi.

---

## Kế hoạch 8 tuần và cổng nghiệm thu

| Tuần | Cổng chung | Duy | Nguyên | Kiệt |
|---|---|---|---|---|
| 1 | Budget, Region, repo, workload chốt | Quy ước tag/IaC | Thiết kế placement test | Thiết kế workflow |
| 2 | Workload local, ECR và ECS baseline | Deploy nền tảng | Chuẩn bị task/placement | DynamoDB/Lambda/State Machine skeleton |
| 3 | API chạy, log lên CloudWatch | Inventory, lifecycle | Binpack/Spread | Workflow success |
| 4 | Tích hợp lần 1 | API/EC2 scaling | AWS Batch | Duplicate + Retry/Catch |
| 5 | Scheduler và workflow kết nối | Rightsizing/idle review | EventBridge Scheduler | Failure injection |
| 6 | Dashboard và chi phí | Phân tích chi phí | Tổng hợp metric | Tổng hợp execution metrics |
| 7 | Báo cáo/slide bản nháp | Resource chapter | Scheduling chapter | Orchestration + proposal |
| 8 | Tổng duyệt, quay video, cleanup | Demo resource | Demo scheduling | Demo orchestration |

### Điều kiện hoàn thành

- [ ] Workload local hoạt động.
- [ ] Image được push lên ECR.
- [ ] ECS API service healthy.
- [ ] ECS chạy bằng EC2 capacity provider.
- [ ] Binpack và Spread được quan sát trên ít nhất hai EC2 hosts.
- [ ] Có số liệu phân biệt task scaling và host scaling.
- [ ] AWS Batch job đạt trạng thái terminal.
- [ ] EventBridge Scheduler chạy ECS task đúng lịch.
- [ ] Step Functions success, duplicate và failure path đều có ảnh.
- [ ] Dashboard, Cost Explorer và bảng phân tích được lưu.
- [ ] Cleanup được xác minh.

## Tài liệu AWS chính thức

- ECS task placement và giới hạn Fargate: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-placement.html
- ECS task placement strategies: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-placement-strategies.html
- ECS EC2 capacity providers: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/asg-capacity-providers.html
- ECS Application Auto Scaling: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-auto-scaling.html
- AWS Batch compute environments: https://docs.aws.amazon.com/batch/latest/userguide/create-compute-environment.html
- AWS Batch service-linked roles: https://docs.aws.amazon.com/batch/latest/userguide/using-service-linked-roles-batch-general.html
- EventBridge Scheduler ECS parameters: https://docs.aws.amazon.com/scheduler/latest/APIReference/API_EcsParameters.html
- Step Functions ECS integration: https://docs.aws.amazon.com/step-functions/latest/dg/connect-ecs.html
- AWS Budgets: https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Cost allocation tags: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html
- AWS Free Tier/current account plans: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier.html
