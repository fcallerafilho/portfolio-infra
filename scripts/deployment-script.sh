# infrastructure deployment script

set -e  # exit on any error

# variables
VPC_NAME="portfolio-vpc"
SUBNET_NAME="portfolio-public-subnet"
IGW_NAME="portfolio-igw"
SG_NAME="portfolio-sg"
INSTANCE_NAME="portfolio-server"
KEY_NAME="portfolio-key"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"

# colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_step() {
    echo -e "${BLUE} Step $1: $2${NC}"
}

print_success() {
    echo -e "${GREEN} $1${NC}"
}

print_error() {
    echo -e "${RED} $1${NC}"
    exit 1
}

# step 1 - create VPC
print_step "1" "Creating VPC"
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
    --query 'Vpc.VpcId' \
    --output text)

if [ -z "$VPC_ID" ]; then
    print_error "Failed to create VPC"
fi
print_success "VPC created: $VPC_ID"

# step 2 - create internet gateway
print_step "2" "Creating Internet Gateway"
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME}]" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

# attach IGW to VPC
aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID

print_success "Internet Gateway created and attached: $IGW_ID"

# step 3 - create public subnet
print_step "3" "Creating Public Subnet"
SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET_CIDR \
    --availability-zone $(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text) \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$SUBNET_NAME}]" \
    --query 'Subnet.SubnetId' \
    --output text)

# enable auto-assign public IP
aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET_ID \
    --map-public-ip-on-launch

print_success "Public Subnet created: $SUBNET_ID"

# step 4 - configure route table
print_step "4" "Configuring Route Table"
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)

# add route to internet gateway
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID

# associate route table with subnet
aws ec2 associate-route-table \
    --route-table-id $ROUTE_TABLE_ID \
    --subnet-id $SUBNET_ID

print_success "Route Table configured: $ROUTE_TABLE_ID"

# step 5 - create security group
print_step "5" "Creating Security Group"
SG_ID=$(aws ec2 create-security-group \
    --group-name $SG_NAME \
    --description "Security group for portfolio website" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME}]" \
    --query 'GroupId' \
    --output text)

# add inbound rules
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0

print_success "Security Group created: $SG_ID"

# step 6 - create key pair (if not exists)
print_step "6" "Checking/Creating Key Pair"
if ! aws ec2 describe-key-pairs --key-names $KEY_NAME &>/dev/null; then
    aws ec2 create-key-pair \
        --key-name $KEY_NAME \
        --query 'KeyMaterial' \
        --output text > ${KEY_NAME}.pem
    chmod 400 ${KEY_NAME}.pem
    print_success "Key pair created: ${KEY_NAME}.pem"
else
    print_success "Key pair already exists: $KEY_NAME"
fi

# step 7 - launch EC2 instance
print_step "7" "Launching EC2 Instance"
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $(aws ec2 describe-images \
        --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-*" "Name=virtualization-type,Values=hvm" \
        --query 'Images[0].ImageId' \
        --output text) \
    --count 1 \
    --instance-type t2.micro \
    --key-name $KEY_NAME \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data file://user-data.sh \
    --query 'Instances[0].InstanceId' \
    --output text)

print_success "EC2 Instance launched: $INSTANCE_ID"

print_step "8" "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

print_success "Instance is running!"