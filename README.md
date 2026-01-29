# CMS Prior Authorization Payer Backend with FHIR Subscription

A Ballerina-based reference implementation demonstrating FHIR R4 Prior Authorization (PA) workflows with subscription-based notifications. Built with Da Vinci PAS profiles and Azure Health Data Services integration.

## Prerequisites

- [Ballerina](https://ballerina.io/downloads/) 2201.13.1 or later
- Python 3.x (for the mock notification endpoint)
- [Postman](https://www.postman.com/downloads/) (for API testing)
- Azure Health Data Services FHIR Server (configured in `Config.toml`)

## Project Structure

```
├── service.bal                    # Main service with API endpoints
├── Config.toml                    # Azure FHIR configuration
├── Ballerina.toml                 # Package metadata
├── modules/
│   ├── models/                    # FHIR resource types
│   ├── repository/                # Azure FHIR data operations
│   ├── services/                  # Notification & subscription logic
│   └── utils/                     # Helper functions
└── resources/
    ├── mock_endpoint.py           # Python mock notification server
    └── FHIR Subscription.postman_collection.json
```

## Setup Instructions

### 1. Configure Azure FHIR Credentials

Update `Config.toml` with your Azure Health Data Services credentials:

```toml
port = 9090

[wso2.pas_payer_backend.repository]
baseUrl = "<your-fhir-server-url>"
tokenUrl = "https://login.microsoftonline.com/<tenant-id>/oauth2/token"
clientId = "<your-client-id>"
clientSecret = "<your-client-secret>"
scopes = ["<your-fhir-server-url>/.default","user/*.write"]
```

### 2. Start the Python Mock Notification Endpoint

The mock server receives and logs subscription notifications for testing.

```bash
cd resources
python3 mock_endpoint.py
```

You should see:
```
Mock endpoint running on http://localhost:8080
```

Keep this terminal open to observe incoming notifications.

### 3. Build and Run the Ballerina Service

In a new terminal:

```bash
bal build
bal run
```

The service starts on multiple ports:
| Port | Service |
|------|---------|
| 9091 | Claim API (`/fhir/r4/Claim`) |
| 9092 | ClaimResponse API (`/fhir/r4/ClaimResponse`) |
| 9093 | Subscription API (`/fhir/r4/Subscription`) |
| 9099 | Health Check (`/fhir/r4/health`) |

### 4. Import Postman Collection

1. Open Postman
2. Click **Import**
3. Select `resources/FHIR Subscription.postman_collection.json`

## Testing the Workflow

Follow these steps using the Postman collection to test the complete PA workflow with notifications:

### Step 1: Health Check

**Request:** `GET http://localhost:9099/fhir/r4/health`

Verify the service is running and connected to Azure FHIR.

**Expected Response:**
```json
{
  "status": "UP",
  "version": "0.1.0",
  "fhir_version": "R4",
  "backend": "Azure Health Data Services"
}
```

### Step 2: Submit a Prior Authorization Request

**Request:** `POST http://localhost:9091/fhir/r4/Claim/$submit`

Submit a claim bundle with provider NPI identifier. The Postman collection includes a sample payload with:
- Claim type: `professional`
- Use: `preauthorization`
- Provider NPI: `1234567890`
- CPT code: `99213` (office visit)

**Expected Response:** A Bundle containing a ClaimResponse with:
- Outcome: `queued`
- PreAuthRef: `PA-{timestamp}`

**Note the ClaimResponse ID** from the response for Step 4.

### Step 3: Create a Subscription

**Request:** `POST http://localhost:9093/fhir/r4/Subscription`

Create a subscription to receive notifications when ClaimResponses are updated for your organization.

Key fields in the Postman payload:
- **Endpoint:** `http://localhost:8080` (the mock server)
- **Organization filter:** `org-identifier=1234567890` (matches the provider NPI)
- **Payload type:** `full-resource`
- **Auth header:** `Authorization: Bearer your-secret-token`

**Expected Response:** `201 Created` with the subscription resource and `status: active`

The mock endpoint terminal should show a handshake notification.

### Step 4: Approve the Prior Authorization

**Request:** `PUT http://localhost:9092/fhir/r4/ClaimResponse/{id}`

Update the ClaimResponse ID from Step 2 in the URL. The Postman payload changes:
- Outcome: `complete`
- Disposition: `Prior authorization approved`

**Expected Response:** `200 OK` with the updated ClaimResponse

**Check the mock endpoint terminal** - you should see the notification bundle containing:
- SubscriptionStatus parameters
- Full ClaimResponse resource

## API Reference

### Claim API (Port 9091)

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/fhir/r4/Claim/$submit` | Submit a prior authorization claim |

### ClaimResponse API (Port 9092)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/fhir/r4/ClaimResponse/{id}` | Retrieve a ClaimResponse |
| PUT | `/fhir/r4/ClaimResponse/{id}` | Update ClaimResponse (triggers notifications) |

### Subscription API (Port 9093)

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/fhir/r4/Subscription` | Create a new subscription |

## Notification Flow

```
1. Claim submitted with provider NPI
         ↓
2. ClaimResponse created (outcome: "queued")
         ↓
3. Subscription created for organization (NPI)
         ↓
4. ClaimResponse updated (outcome: "complete")
         ↓
5. Notification sent to all active subscriptions
   matching the organization identifier
```

## Mock Endpoint Details

The Python mock server (`resources/mock_endpoint.py`) is a simple HTTP server that:

- Listens on `http://localhost:8080`
- Accepts POST requests with JSON payloads
- Prints formatted notification content to console
- Returns `{"status": "received"}` with HTTP 200

This allows you to observe the FHIR R4 Backport notification bundles being sent when ClaimResponses are updated.

## Troubleshooting

**Service won't start:**
- Ensure Ballerina 2201.13.1+ is installed
- Verify `Config.toml` has valid Azure credentials

**Notifications not received:**
- Confirm the mock endpoint is running on port 8080
- Check that the subscription was created with `status: active`
- Verify the organization identifier matches between claim and subscription

**Handshake failed:**
- Ensure the mock endpoint is running before creating subscriptions
- Check firewall settings allow localhost connections


## Pending Items

- Incoperate Ballerina records from [davincipas lib](https://central.ballerina.io/ballerinax/health.fhir.r4.davincipas/3.0.0)
- Write tests to validate service layer
