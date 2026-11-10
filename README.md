# CO3141 - Resource Management, Scheduling & Orchestration

Starter kit triển khai cho nhóm **3buanhan**: Duy / Nguyên / Kiệt. Đây là bộ lab phục vụ học tập, không phải cấu hình production. Làm theo `docs/runbook.md` theo thứ tự; không chạy từng module trên ba hạ tầng độc lập.

## Mô hình nhóm

- **Duy:** CloudFormation nền tảng, VPC/ECS/EC2, Resource Management, Auto Scaling, inventory, rightsizing và chi phí.
- **Nguyên:** ECS Binpack/Spread trên EC2, AWS Batch và EventBridge Scheduler.
- **Kiệt:** DynamoDB idempotency, Lambda, Step Functions với ECS RunTask `.sync`, Retry/Catch.
- **Cả ba:** tích hợp liên tục, CloudWatch, báo cáo, demo và cleanup.

## Cấu trúc

- `workload/`: FastAPI API + worker + Dockerfile, cùng một image cho toàn bộ demo.
- `cloudformation/data-foundation.yaml`: ECR, S3, DynamoDB, CloudWatch Log Group.
- `cloudformation/shared-infra.yaml`: VPC, public subnets, security groups, ECS cluster, EC2 ASG/capacity provider, ALB.
- `cloudformation/ecs-service.yaml`: API/worker task definitions, API service và CPU target tracking.
- `cloudformation/orchestration.yaml`: hai Lambda inline, IAM permissions và Step Functions state machine.
- `cloudformation/batch.yaml`: AWS Batch managed EC2 compute environment (min/desired vCPU = 0), queue và job definition.
- `cloudformation/scheduler.yaml`: one-time EventBridge Scheduler target cho ECS worker task.
- `scripts/`: deploy/test/load/placement/Batch/Scheduler/Kubernetes helpers cho Windows PowerShell.
- `k8s/`: kind cluster + Kubernetes topology-spread demo (optional; không phải EKS thật).
- `docs/runbook.md`: hướng dẫn theo thứ tự từ đầu đến cuối.

## Những lựa chọn kỹ thuật phải nhớ

1. Dùng **ECS EC2** cho Binpack/Spread. Fargate không hỗ trợ task placement strategies/constraints.
2. Một AWS account/Region chung chỉ khi chủ tài khoản cho phép. Không chia sẻ root credential; dùng identity riêng cho từng thành viên.
3. Region mẫu: `ap-southeast-1`.
4. Public-subnet lab có public IPv4 cho EC2 hosts và ALB HTTP chỉ mở tới IP `/32` của nhóm. Không có SSH ingress. Đây không phải production network design.
5. AWS Budgets chỉ gửi cảnh báo; không phải hard spending cap. ECR repository dùng `EmptyOnDelete: true` để stack data-foundation xóa được các image đã push.
6. ECR tag bất biến. Dùng `v1`, `v2`, ... và không cố push đè cùng một tag.
7. AWS Batch compute environment được cấu hình `MinvCpus=0`, `DesiredvCpus=0`, nhưng khi submit job có thể phát sinh EC2 cost.

## 1. Local test nhanh

PowerShell:

```powershell
cd workload
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app:app --reload --port 8000
```

Cửa sổ PowerShell khác:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health
Invoke-RestMethod 'http://127.0.0.1:8000/work?seconds=2'
python .\worker.py --seconds 3
python .\worker.py --seconds 1 --fail
```

## 2. Deploy hạ tầng lõi

Cài AWS CLI v2 + Docker Desktop (Linux containers), rồi cấu hình profile:

```powershell
aws configure --profile co3141
aws sts get-caller-identity --profile co3141
```

Từ thư mục gốc repository, lấy public IP và triển khai:

```powershell
$myIp = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
.\scripts\deploy-project.ps1 -AllowedIngressCidr "$myIp/32" -Profile co3141 -Region ap-southeast-1 -ImageTag v1 -InstanceType t3.small
```

Script deploy data foundation, build/push image, shared infrastructure, ECS service và Step Functions orchestration. Xem hướng dẫn chi tiết và cách kiểm tra ở `docs/runbook.md`.

## 3. Test API và scaling

```powershell
$baseUrl = "http://<ALB-DNS-NAME>"
.\scripts\test-api.ps1 -BaseUrl $baseUrl
.\scripts\load-api.ps1 -BaseUrl $baseUrl -Workers 8 -RequestsPerWorker 3 -Seconds 5
```

## 4. Binpack / Spread (Nguyên)

Đầu tiên tạm tăng ASG desired capacity lên 2 và chờ hai ECS container instances `ACTIVE` (chi tiết trong runbook). Sau đó:

```powershell
$env:ECS_CLUSTER = "co3141-cluster"
$env:ECS_WORKER_TASK = "co3141-worker"
$env:ECS_CAPACITY_PROVIDER = "co3141-ec2-capacity"
.\scripts\run-placement.ps1 -Strategy binpack -Count 10
.\scripts\run-placement.ps1 -Strategy spread -Count 10
```

Chờ nhóm task của lần đầu hoàn tất trước khi bắt đầu lần thứ hai.

Worker placement task dùng CPU reservation 256 units và memory 128 MiB để 10 task cần nhiều hơn một `t3.small`; kết quả thực tế vẫn phụ thuộc tình trạng host và phải ghi số liệu quan sát.

## 5. AWS Batch và EventBridge Scheduler (Nguyên)

```powershell
.\scripts\deploy-batch.ps1 -Profile co3141 -Region ap-southeast-1 -ImageTag v1
.\scripts\run-batch.ps1 -Profile co3141 -Region ap-southeast-1 -JobName co3141-demo-01

$at = (Get-Date).AddMinutes(10).ToString("yyyy-MM-ddTHH:mm:ss")
.\scripts\create-schedule.ps1 -ScheduleAt $at -Profile co3141 -Region ap-southeast-1 -Timezone Asia/Ho_Chi_Minh
```

Xóa các stack `co3141-batch` và `co3141-scheduler` sau khi lấy đủ bằng chứng; không để compute environment hoặc schedule tồn tại ngoài thời gian cần thiết.

## 6. Kubernetes Scheduler bằng kind (optional)

Chỉ chạy khi giảng viên yêu cầu thêm phần Kubernetes/EKS scheduler. Cần Docker Desktop, `kind`, `kubectl`:

```powershell
.\scripts\run-kind-demo.ps1
kubectl get pods -n co3141 -o wide
.\scripts\cleanup-kind-demo.ps1
```

Đây là Kubernetes cục bộ, không phải AWS EKS và không phát sinh EKS control-plane charge.

## 7. Step Functions (Kiệt)

State machine ARN lấy từ output stack `co3141-orchestration`. Input luôn có `jobId` và `fail` dạng string:

- Thành công: `{"jobId":"demo-success-001","fail":"false"}`
- Duplicate: chạy lại đúng `jobId` trên với tên execution mới.
- Retry/Catch: `{"jobId":"demo-failure-001","fail":"true"}`

Worker chủ động thoát mã lỗi khi `FAIL_MODE=true`. Chi tiết lệnh CLI và kiểm tra DynamoDB ở `docs/runbook.md`.

## Cleanup

Không bỏ qua. Xóa theo thứ tự: scheduler, batch, orchestration, ECS service, shared infra, data foundation. Dừng task, empty S3 bucket trước khi xóa data stack và kiểm tra Billing/Cost Explorer sau khi cleanup. Xem lệnh cụ thể ở Stage 9 trong runbook.

## Quick notes

- Không commit `.aws`, `.env`, API keys, private keys hoặc AWS credentials.
- Không mở ALB cho `0.0.0.0/0` trong lab này.
- Không dùng Fargate cho so sánh Binpack/Spread.
- Không tuyên bố placement ra kết quả 6-0/3-3 trước khi có dữ liệu.
- Starter kit chỉ tạo template/script. Nhóm phải deploy vào AWS account được cấp quyền; chưa có tài nguyên nào được tạo trong AWS bởi việc tải file này.
