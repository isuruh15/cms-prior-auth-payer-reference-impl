// main.bal
// CMS Prior Authorization Payer Backend with Azure FHIR Integration

import ballerina/http;
import ballerina/log;
import ballerina/uuid;
import ballerina/time;
import ballerinax/health.fhir.r4.international401;
import ballerinax/health.clients.fhir as fhirClient;
import wso2/pas_payer_backend.models;
import wso2/pas_payer_backend.repository;
import wso2/pas_payer_backend.services;
import wso2/pas_payer_backend.utils as fhirUtils;

# Initialize FHIR Connector for Azure Health Data Services
final fhirClient:FHIRConnector fhirConnector = check repository:initFhirConnector();

# Initialize repositories with FHIR Connector
final repository:ClaimRepository claimRepo = new (fhirConnector);
final repository:SubscriptionRepository subscriptionRepo = new (fhirConnector);

# Initialize services
final services:SubscriptionService subscriptionService = new (subscriptionRepo);
final services:NotificationService notificationService = new (subscriptionRepo);

configurable string host = "localhost";
configurable int port = 9090;

# FHIR Server REST API
service /fhir on new http:Listener(port) {

    # Submit Claim (PA Request)
    #
    # + return - ClaimResponse bundle
    resource function post Claim/\$submit(http:Request request)
            returns http:Response|error {

        http:Response response = new;

        do {
            // Parse request bundle
            json payload = check request.getJsonPayload();

            // Extract Claim - work with JSON for flexibility
            string claimId = (check payload.id).toString();
            if claimId == "" {
                claimId = uuid:createType1AsString();
            }
            string claimResponseId = uuid:createType1AsString();

            // Extract organization ID from provider identifier
            string orgId = "";
            json|error provider = payload.provider;
            if provider is json {
                json|error identifier = provider.identifier;
                if identifier is json {
                    json|error value = identifier.value;
                    if value is string {
                        orgId = value;
                    }
                }
            }

            // Get claim type, use, patient, insurer from payload
            json claimType = check payload.'type;
            json claimUse = check payload.use;
            json claimPatient = check payload.patient;
            json|error claimInsurer = payload.insurer;

            // Create pended ClaimResponse as JSON
            json claimResponseJson = {
                "resourceType": "ClaimResponse",
                "id": claimResponseId,
                "status": "active",
                "type": claimType,
                "use": claimUse,
                "patient": claimPatient,
                "created": time:utcToString(time:utcNow()),
                "insurer": claimInsurer is json ? claimInsurer : {"reference": "Organization/payer-001"},
                "request": {"reference": string `Claim/${claimId}`},
                "outcome": "queued",
                "disposition": "Prior authorization pending review",
                "preAuthRef": string `PA-${time:utcNow()[0]}`
            };

            // Store in Azure FHIR
            check claimRepo.storeClaimResponse(
                claimId,
                claimResponseId,
                orgId,
                "MEMBER-001",
                "pended",
                claimResponseJson
            );

            // Return response
            response.statusCode = 200;
            response.setJsonPayload({
                "resourceType": "Bundle",
                "type": "collection",
                "entry": [
                    {
                        "resource": claimResponseJson
                    }
                ]
            });

            log:printInfo(string `PA submitted: ${claimResponseId}, status: pended (stored in Azure FHIR)`);

        } on fail error e {
            log:printError(string `Error processing claim: ${e.message()}`);
            response.statusCode = 400;
            response.setJsonPayload(fhirUtils:createOperationOutcome(
                "error",
                "invalid",
                e.message()
            ).toJson());
        }

        return response;
    }

    # Create Subscription
    #
    # + return - Created subscription
    resource function post Subscription(http:Request request)
            returns http:Response|error {

        http:Response response = new;

        do {
            json payload = check request.getJsonPayload();
            international401:Subscription subscription = check payload.cloneWithType(international401:Subscription);

            // Create subscription
            international401:Subscription created =
                check subscriptionService.createSubscription(subscription);

            response.statusCode = 201;
            response.setJsonPayload(created.toJson());
            response.setHeader("Location", string `/fhir/Subscription/${created.id ?: ""}`);

            log:printInfo(string `Subscription created: ${created.id ?: ""} (stored in Azure FHIR)`);

        } on fail error e {
            log:printError(string `Error creating subscription: ${e.message()}`);
            response.statusCode = 400;
            response.setJsonPayload(fhirUtils:createOperationOutcome(
                "error",
                "invalid",
                e.message()
            ).toJson());
        }

        return response;
    }

    # Update ClaimResponse (for testing - simulates PA approval)
    #
    # + id - ClaimResponse ID
    # + return - Updated ClaimResponse
    resource function put ClaimResponse/[string id](http:Request request)
            returns http:Response|error {

        http:Response response = new;

        do {
            json payload = check request.getJsonPayload();

            // Extract outcome from payload
            string outcome = (check payload.outcome).toString();

            // Update in Azure FHIR
            string orgId = check claimRepo.updateClaimResponse(
                id,
                outcome,
                payload
            );

            // Convert payload to ClaimResponse for notification
            international401:ClaimResponse claimResponse = check payload.cloneWithType(international401:ClaimResponse);

            // Send notifications
            check notificationService.sendNotifications(id, orgId, claimResponse);

            response.statusCode = 200;
            response.setJsonPayload(payload);

            log:printInfo(string `ClaimResponse ${id} updated in Azure FHIR, notifications sent`);

        } on fail error e {
            log:printError(string `Error updating ClaimResponse: ${e.message()}`);
            response.statusCode = 400;
            response.setJsonPayload(fhirUtils:createOperationOutcome(
                "error",
                "invalid",
                e.message()
            ).toJson());
        }

        return response;
    }

    # Get ClaimResponse by ID
    #
    # + id - ClaimResponse ID
    # + return - ClaimResponse resource
    resource function get ClaimResponse/[string id]()
            returns http:Response|error {

        http:Response response = new;

        do {
            models:ClaimRecord claimRecord = check claimRepo.getClaimResponse(id);

            response.statusCode = 200;
            response.setJsonPayload(claimRecord.payload);

        } on fail error e {
            log:printError(string `Error getting ClaimResponse: ${e.message()}`);
            response.statusCode = 404;
            response.setJsonPayload(fhirUtils:createOperationOutcome(
                "error",
                "not-found",
                e.message()
            ).toJson());
        }

        return response;
    }

    # Health check endpoint
    resource function get health() returns json {
        return {
            "status": "UP",
            "version": "0.1.0",
            "fhir_version": "R4",
            "backend": "Azure Health Data Services"
        };
    }
}

# Application entry point
public function main() returns error? {
    log:printInfo("PAS Payer Backend started on http://localhost:9090/fhir");
    log:printInfo("Connected to Azure Health Data Services FHIR Server");
}
