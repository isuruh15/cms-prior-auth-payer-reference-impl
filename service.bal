// service.bal
// CMS Prior Authorization Payer Backend with Azure FHIR Integration

import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;
import ballerinax/health.clients.fhir as fhirClient;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.international401;
import ballerinax/health.fhir.r4.davincipas;
import ballerinax/health.fhirr4;

import wso2/pas_payer_backend.models;
import wso2/pas_payer_backend.repository;
import wso2/pas_payer_backend.services;
import wso2/pas_payer_backend.utils;

// Initialize FHIR Connector for Azure Health Data Services
final fhirClient:FHIRConnector fhirConnector = check repository:initFhirConnector();

// Initialize repositories with FHIR Connector
final repository:ClaimRepository claimRepo = new (fhirConnector);
final repository:SubscriptionRepository subscriptionRepo = new (fhirConnector);

// Initialize services
final services:SubscriptionService subscriptionService = new (subscriptionRepo);
final services:NotificationService notificationService = new (subscriptionRepo);

configurable string host = "localhost";
configurable int port = 9090;

// ######################################################################################################################
// # FHIR API Configurations                                                                                            #
// ######################################################################################################################

final r4:ResourceAPIConfig claimApiConfig = {
    resourceType: "Claim",
    profiles: [],
    defaultProfile: (),
    searchParameters: [
        {
            name: "_id",
            active: true,
            information: {
                description: "Logical id of this artifact",
                builtin: false,
                documentation: "http://hl7.org/fhir/SearchParameter/Resource-id"
            }
        }
    ],
    operations: [
        {
            name: "submit",
            active: true
        }
    ],
    serverConfig: (),
    authzConfig: ()
};

final r4:ResourceAPIConfig claimResponseApiConfig = {
    resourceType: "ClaimResponse",
    profiles: [],
    defaultProfile: (),
    searchParameters: [
        {
            name: "_id",
            active: true,
            information: {
                description: "Logical id of this artifact",
                builtin: false,
                documentation: "http://hl7.org/fhir/SearchParameter/Resource-id"
            }
        },
        {
            name: "patient",
            active: true,
            information: {
                description: "Patient receiving the products or services",
                builtin: false,
                documentation: "http://hl7.org/fhir/SearchParameter/ClaimResponse-patient"
            }
        }
    ],
    operations: [],
    serverConfig: (),
    authzConfig: ()
};

final r4:ResourceAPIConfig subscriptionApiConfig = {
    resourceType: "Subscription",
    profiles: ["http://hl7.org/fhir/us/davinci-pas/StructureDefinition/profile-subscription"],
    defaultProfile: (),
    searchParameters: [
        {
            name: "_id",
            active: true,
            information: {
                description: "Logical id of this artifact",
                builtin: false,
                documentation: "http://hl7.org/fhir/SearchParameter/Resource-id"
            }
        },
        {
            name: "status",
            active: true,
            information: {
                description: "The current state of the subscription",
                builtin: false,
                documentation: "http://hl7.org/fhir/SearchParameter/Subscription-status"
            }
        }
    ],
    operations: [],
    serverConfig: (),
    authzConfig: ()
};

// Type aliases for FHIR resources
public type Claim international401:Claim;
public type ClaimResponse international401:ClaimResponse;
public type Subscription international401:Subscription|davincipas:PASSubscription;
public type Parameters international401:Parameters;

// ######################################################################################################################
// # Claim API                                                                                                          #
// ######################################################################################################################

service /fhir/r4/Claim on new fhirr4:Listener(config = claimApiConfig, port = 9091) {

    // Submit Claim (PA Request) - $submit operation
    // Accepts a Bundle containing a Claim resource
    isolated resource function post \$submit(r4:FHIRContext fhirContext, r4:Bundle bundle) returns http:Response|r4:FHIRError {
        http:Response response = new;

        do {
            // Get the JSON payload from the parameters
            json payload = bundle.toJson();

            // Extract Claim from Bundle entry if present
            json claimResource = payload;
            json|error resourceType = payload.resourceType;
            if resourceType is string && resourceType == "Bundle" {
                json|error entries = payload.entry;
                if entries is json[] && entries.length() > 0 {
                    json|error firstEntry = entries[0];
                    if firstEntry is json {
                        json|error res = firstEntry.'resource;
                        if res is json {
                            claimResource = res;
                        }
                    }
                }
            }

            // Extract Claim ID
            string claimId = "";
            json|error claimIdJson = claimResource.id;
            if claimIdJson is string {
                claimId = claimIdJson;
            }
            if claimId == "" {
                claimId = uuid:createType1AsString();
            }
            string claimResponseId = uuid:createType1AsString();

            // Extract organization ID from provider identifier
            string orgId = "";
            json|error provider = claimResource.provider;
            if provider is json {
                json|error identifier = provider.identifier;
                if identifier is json {
                    json|error value = identifier.value;
                    if value is string {
                        orgId = value;
                    }
                }
            }

            // Get claim type, use, patient, insurer from claim
            json claimType = check claimResource.'type;
            json claimUse = check claimResource.use;
            json claimPatient = check claimResource.patient;
            json|error claimInsurer = claimResource.insurer;

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

            // Return response bundle
            response.statusCode = http:STATUS_OK;
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
            return r4:createFHIRError(
                e.message(),
                r4:ERROR,
                r4:INVALID,
                httpStatusCode = http:STATUS_BAD_REQUEST
            );
        }

        return response;
    }

    // Read the current state of single resource based on its id
    isolated resource function get [string id](r4:FHIRContext fhirContext) returns r4:DomainResource|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Search for resources based on a set of criteria
    isolated resource function get .(r4:FHIRContext fhirContext) returns r4:Bundle|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Create a new resource
    isolated resource function post .(r4:FHIRContext fhirContext, Claim claim) returns r4:DomainResource|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }
}

// ######################################################################################################################
// # ClaimResponse API                                                                                                  #
// ######################################################################################################################

service /fhir/r4/ClaimResponse on new fhirr4:Listener(config = claimResponseApiConfig, port = 9092) {

    // Read the current state of single resource based on its id
    isolated resource function get [string id](r4:FHIRContext fhirContext) returns http:Response|r4:FHIRError {
        http:Response response = new;

        do {
            models:ClaimRecord claimRecord = check claimRepo.getClaimResponse(id);

            response.statusCode = http:STATUS_OK;
            response.setJsonPayload(claimRecord.payload);

        } on fail error e {
            log:printError(string `Error getting ClaimResponse: ${e.message()}`);
            return r4:createFHIRError(
                e.message(),
                r4:ERROR,
                r4:PROCESSING,
                httpStatusCode = http:STATUS_NOT_FOUND
            );
        }

        return response;
    }

    // Search for resources based on a set of criteria
    isolated resource function get .(r4:FHIRContext fhirContext) returns r4:Bundle|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Create a new resource
    isolated resource function post .(r4:FHIRContext fhirContext, ClaimResponse claimResponse) returns http:Response|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Update the current state of a resource completely
    isolated resource function put [string id](r4:FHIRContext fhirContext, ClaimResponse claimResponse) returns http:Response|r4:FHIRError {
        http:Response response = new;

        do {
            json payload = claimResponse.toJson();

            // Extract outcome from payload
            string outcome = claimResponse.outcome.toString();

            // Update in Azure FHIR
            string orgId = check claimRepo.updateClaimResponse(
                id,
                outcome,
                payload
            );

            // Send notifications
            check notificationService.sendNotifications(id, orgId, claimResponse);

            response.statusCode = http:STATUS_OK;
            response.setJsonPayload(payload);

            log:printInfo(string `ClaimResponse ${id} updated in Azure FHIR, notifications sent`);

        } on fail error e {
            log:printError(string `Error updating ClaimResponse: ${e.message()}`);
            return r4:createFHIRError(
                e.message(),
                r4:ERROR,
                r4:INVALID,
                httpStatusCode = http:STATUS_BAD_REQUEST
            );
        }

        return response;
    }

    // Delete a resource
    isolated resource function delete [string id](r4:FHIRContext fhirContext) returns r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }
}

// ######################################################################################################################
// # Subscription API                                                                                                   #
// ######################################################################################################################

service /fhir/r4/Subscription on new fhirr4:Listener(config = subscriptionApiConfig, port = 9093) {

    // Read the current state of single resource based on its id
    isolated resource function get [string id](r4:FHIRContext fhirContext) returns r4:DomainResource|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Search for resources based on a set of criteria
    isolated resource function get .(r4:FHIRContext fhirContext) returns r4:Bundle|r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Create a new subscription (supports R4 Backport format with _criteria extensions)
    isolated resource function post .(r4:FHIRContext fhirContext, Subscription subscription) returns http:Response|r4:FHIRError {
        http:Response response = new;

        do {
            json payload = subscription.toJson();

            // Extract organization ID from _criteria extension (R4 Backport format)
            string organizationId = check extractOrgIdFromJson(payload);

            // Extract endpoint from channel
            string endpoint = subscription.channel.endpoint ?: "";

            if endpoint == "" {
                return r4:createFHIRError(
                    "Subscription endpoint is required",
                    r4:ERROR,
                    r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST
                );
            }

            // Check if subscription already exists
            boolean exists = check subscriptionRepo.subscriptionExists(organizationId, endpoint);
            if exists {
                log:printInfo(string `Subscription already exists for org ${organizationId}`);
                return r4:createFHIRError(
                    "Subscription already exists",
                    r4:ERROR,
                    r4:PROCESSING,
                    httpStatusCode = http:STATUS_CONFLICT
                );
            }

            // Generate subscription ID
            string subscriptionId = uuid:createType1AsString();

            // Extract payload type from _payload extension (R4 Backport format)
            string payloadType = extractPayloadTypeFromJson(payload);

            // Build PASSubscription record
            davincipas:PASSubscriptionChannel channel = {
                'type: davincipas:CODE_TYPE_REST_HOOK,
                endpoint: endpoint,
                payload: davincipas:CODE_PAYLOAD_VALUE
            };

            // Add channel headers if present
            string? authHeader = extractAuthHeaderFromJson(payload);
            if authHeader is string {
                channel.header = [authHeader];
            }

            // Add channel extension for payload type
            channel.extension = [
                {
                    url: "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-payload-content",
                    valueCode: payloadType
                }
            ];

            // Build subscription extensions
            r4:Extension[] extensions = [
                {
                    url: "http://example.org/fhir/StructureDefinition/organization-identifier",
                    valueString: organizationId
                },
                {
                    url: "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-filter-criteria",
                    valueString: string `org-identifier=${organizationId}`
                }
            ];

            // Create PASSubscription resource
            davincipas:PASSubscription pasSubscription = {
                id: subscriptionId,
                status: davincipas:CODE_STATUS_REQUESTED,
                reason: "ClaimResponse status change notifications",
                criteria: "ClaimResponse?outcome:not=queued",
                channel: channel,
                extension: extensions
            };

            // Store in Azure FHIR
            _ = check subscriptionRepo.createSubscription(pasSubscription);

            // Send handshake
            boolean handshakeSuccess = check sendHandshakeNotification(subscriptionId, pasSubscription);

            davincipas:PASSubscriptionStatus finalStatus = handshakeSuccess
                ? davincipas:CODE_STATUS_ACTIVE
                : davincipas:CODE_STATUS_ERROR;
            check subscriptionRepo.updateStatus(subscriptionId, finalStatus);

            // Build response with updated status
            pasSubscription.status = finalStatus;
            pasSubscription.meta = {
                versionId: "1",
                lastUpdated: time:utcToString(time:utcNow())
            };

            response.statusCode = http:STATUS_CREATED;
            response.setJsonPayload(pasSubscription.toJson());
            response.setHeader("Location", string `/fhir/r4/Subscription/${subscriptionId}`);

            log:printInfo(string `Subscription created: ${subscriptionId} (stored in Azure FHIR)`);

        } on fail error e {
            log:printError(string `Error creating subscription: ${e.message()}`);
            return r4:createFHIRError(
                e.message(),
                r4:ERROR,
                r4:INVALID,
                httpStatusCode = http:STATUS_BAD_REQUEST
            );
        }

        return response;
    }

    // Update the current state of a resource completely
    isolated resource function put [string id](r4:FHIRContext fhirContext, Subscription subscription) returns r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }

    // Delete a resource
    isolated resource function delete [string id](r4:FHIRContext fhirContext) returns r4:FHIRError {
        return r4:createFHIRError("Not implemented", r4:ERROR, r4:INFORMATIONAL, httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
    }
}

// ######################################################################################################################
// # Health Check API                                                                                                   #
// ######################################################################################################################

service /fhir/r4 on new http:Listener(9099) {

    // Health check endpoint
    resource function get health() returns json {
        return {
            "status": "UP",
            "version": "0.1.0",
            "fhir_version": "R4",
            "backend": "Azure Health Data Services"
        };
    }
}

// ######################################################################################################################
// # Helper Functions                                                                                                   #
// ######################################################################################################################

// Extract organization ID from _criteria extension (R4 Backport format)
isolated function extractOrgIdFromJson(json payload) returns string|error {
    json|error criteriaExt = payload._criteria;
    if criteriaExt is json {
        // _criteria is an object with an extension array
        json|error extensions = criteriaExt.extension;
        if extensions is json[] {
            foreach json ext in extensions {
                json|error url = ext.url;
                if url is string && url.includes("backport-filter-criteria") {
                    json|error valueString = ext.valueString;
                    if valueString is string {
                        // Parse "org-identifier=1234567890"
                        string[] parts = re `=`.split(valueString);
                        if parts.length() == 2 && parts[0] == "org-identifier" {
                            return parts[1];
                        }
                    }
                }
            }
        }
    }
    return error("org-identifier filter not found in _criteria extension");
}

// Extract payload type from _payload extension (R4 Backport format)
isolated function extractPayloadTypeFromJson(json payload) returns string {
    json|error channelJson = payload.channel;
    if channelJson is json {
        json|error payloadExt = channelJson._payload;
        if payloadExt is json {
            // _payload is an object with an extension array
            json|error extensions = payloadExt.extension;
            if extensions is json[] {
                foreach json ext in extensions {
                    json|error url = ext.url;
                    if url is string && url.includes("backport-payload-content") {
                        json|error valueCode = ext.valueCode;
                        if valueCode is string {
                            return valueCode;
                        }
                    }
                }
            }
        }
    }
    return "full-resource";
}

// Extract authorization header from channel headers
isolated function extractAuthHeaderFromJson(json payload) returns string? {
    json|error channelJson = payload.channel;
    if channelJson is json {
        json|error headers = channelJson.header;
        if headers is json[] {
            foreach json header in headers {
                if header is string && header.startsWith("Authorization:") {
                    return header;
                }
            }
        }
    }
    return ();
}

// Send handshake notification to subscription endpoint
isolated function sendHandshakeNotification(
        string subscriptionId,
        davincipas:PASSubscription subscription
) returns boolean|error {

    string endpoint = subscription.channel.endpoint ?: "";
    if endpoint == "" {
        return error("Subscription endpoint is empty");
    }

    log:printInfo(string `Sending handshake to ${endpoint}`);

    // Build handshake bundle
    json bundle = {
        "resourceType": "Bundle",
        "type": "history",
        "timestamp": time:utcToString(time:utcNow()),
        "entry": [
            {
                "fullUrl": string `urn:uuid:${uuid:createType1AsString()}`,
                "resource": {
                    "resourceType": "Parameters",
                    "parameter": [
                        {
                            "name": "subscription",
                            "valueReference": {
                                "reference": string `Subscription/${subscriptionId}`
                            }
                        },
                        {
                            "name": "type",
                            "valueCode": "handshake"
                        },
                        {
                            "name": "status",
                            "valueCode": "requested"
                        }
                    ]
                }
            }
        ]
    };

    // Send HTTP POST
    http:Client httpClient = check new (endpoint, {
        timeout: 10
    });

    map<string|string[]> headers = {
        "Content-Type": "application/fhir+json"
    };

    // Extract auth header from channel headers
    string? authHeader = utils:extractAuthHeader(subscription);
    if authHeader is string {
        headers["Authorization"] = authHeader;
    }

    http:Response|error response = httpClient->post("/", bundle, headers);

    if response is http:Response {
        if response.statusCode >= 200 && response.statusCode < 300 {
            log:printInfo(string `Handshake successful for ${subscriptionId}`);
            return true;
        }
    }

    log:printError(string `Handshake failed for ${subscriptionId}`);
    return false;
}

// Application entry point
public function main() returns error? {
    log:printInfo("PAS Payer Backend started on http://localhost:9090/fhir/r4");
    log:printInfo("Connected to Azure Health Data Services FHIR Server");
}
