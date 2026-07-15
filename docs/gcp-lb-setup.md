# GCP LOad balancer setup


## DNS

CNAME: ts.bltdirect.com -> <lb-ip-address>

## GCP Setup commands

```bash
## 1. Create the Serverless NEG and Backend Service
Run these commands to prepare the "Typesense" backend:

```bash
# Create a Serverless Network Endpoint Group (NEG) for Cloud Run
gcloud compute network-endpoint-groups create blt-typesense-neg \
    --region=europe-west2 \
    --network-endpoint-type=serverless \
    --cloud-run-service=blt-typesense

# Create the Backend Service for the Load Balancer
gcloud compute backend-services create blt-typesense-backend \
    --global \
    --load-balancing-scheme=EXTERNAL_MANAGED

# Connect the NEG to the Backend Service
gcloud compute backend-services add-backend blt-typesense-backend \
    --global \
    --network-endpoint-group=blt-typesense-neg \
    --network-endpoint-group-region=europe-west2
```

## 2. Update the Load Balancer Host Rules
Assuming you pointed your CNAME to the LB for a domain like typesense.bltdirect.com, use these commands to route traffic to your new backend:

```bash
# Add a Path Matcher to the existing blt-prod-lb
gcloud compute url-maps add-path-matcher blt-prod-lb \
    --default-service=blt-typesense-backend \
    --path-matcher-name=typesense-matcher \
    --global

# Add the Host Rule for your specific domain

gcloud compute url-maps add-host-rule blt-prod-lb \
    --hosts="ts.bltdirect.com" \
    --path-matcher-name=typesense-matcher \
    --global
```

## Security Check

By default, Cloud Run services allow public traffic. Once your Load Balancer is confirmed to be working, it's a best practice to restrict access so that users must go through the LB:

gcloud run services update blt-typesense \
    --region=europe-west2 \
    --ingress=internal-and-cloud-load-balancing
Wait for propagation: Load balancer changes (URL Map updates) typically take 3 to 5 minutes to propagate globally.
