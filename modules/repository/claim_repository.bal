// modules/repository/claim_repository.bal
// Azure FHIR-based Claim Repository

import ballerina/log;
import ballerinax/health.clients.fhir as fhirClient;

import wso2/pas_payer_backend.models;

# Claim Repository for Azure FHIR Server operations
public isolated class ClaimRepository {
    private final fhirClient:FHIRConnector fhirConnector;

    # Initialize repository with FHIR Connector
    #
    # + fhirConnector - Azure FHIR Connector instance
    public isolated function init(fhirClient:FHIRConnector fhirConnector) {
        self.fhirConnector = fhirConnector;
    }

    # Store ClaimResponse in Azure FHIR Server
    #
    # + claimId - Claim ID
    # + claimResponseId - ClaimResponse ID
    # + organizationId - Organization NPI
    # + patientMemberId - Patient member identifier
    # + status - Current status
    # + payload - Full ClaimResponse JSON
    # + return - Error if operation fails
    public isolated function storeClaimResponse(
            string claimId,
            string claimResponseId,
            string organizationId,
            string patientMemberId,
            string status,
            json payload
    ) returns error? {

        // Add organization identifier extension for filtering
        json claimResponseWithMeta = check self.addOrganizationExtension(payload, organizationId, patientMemberId);

        // Create ClaimResponse in Azure FHIR using conditional create
        // This ensures idempotency - if a ClaimResponse with this ID exists, it won't create a duplicate
        map<string[]> condition = {"_id": [claimResponseId]};

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->create(
            claimResponseWithMeta
        // onCondition = condition
        );

        if response is fhirClient:FHIRError {
            log:printError(string `Failed to store ClaimResponse ${claimResponseId}: ${response.message()}`);
            return error(string `Failed to store ClaimResponse: ${response.message()}`);
        }

        log:printInfo(string `Stored ClaimResponse ${claimResponseId} for org ${organizationId} in Azure FHIR`);
    }

    # Update ClaimResponse status in Azure FHIR Server
    #
    # + claimResponseId - ClaimResponse ID
    # + newStatus - New status
    # + payload - Updated ClaimResponse JSON
    # + return - Organization ID for correlation or error
    public isolated function updateClaimResponse(
            string claimResponseId,
            string newStatus,
            json payload
    ) returns string|error {

        // First, get existing ClaimResponse to retrieve organization ID
        fhirClient:FHIRResponse|fhirClient:FHIRError getResponse = self.fhirConnector->getById("ClaimResponse", claimResponseId);

        if getResponse is fhirClient:FHIRError {
            return error(string `ClaimResponse ${claimResponseId} not found: ${getResponse.message()}`);
        }

        // Extract organization ID from extension
        string organizationId = check self.extractOrganizationId(<json>getResponse.'resource);

        // Update the ClaimResponse
        fhirClient:FHIRResponse|fhirClient:FHIRError updateResponse = self.fhirConnector->update(payload);

        if updateResponse is fhirClient:FHIRError {
            log:printError(string `Failed to update ClaimResponse ${claimResponseId}: ${updateResponse.message()}`);
            return error(string `Failed to update ClaimResponse: ${updateResponse.message()}`);
        }

        log:printInfo(string `Updated ClaimResponse ${claimResponseId} to status ${newStatus} in Azure FHIR`);
        return organizationId;
    }

    # Get ClaimResponse by ID from Azure FHIR Server
    #
    # + claimResponseId - ClaimResponse ID
    # + return - ClaimResponse record or error
    public isolated function getClaimResponse(string claimResponseId)
            returns models:ClaimRecord|error {

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->getById("ClaimResponse", claimResponseId);

        if response is fhirClient:FHIRError {
            return error(string `ClaimResponse ${claimResponseId} not found: ${response.message()}`);
        }

        // Convert FHIR resource to internal ClaimRecord format
        return self.toClaimRecord(<json>response.'resource);
    }

    # Get Claim by ID from Azure FHIR Server
    #
    # + claimId - Claim ID
    # + return - Claim JSON or error
    public isolated function getClaim(string claimId) returns json|error {
        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->getById("Claim", claimId);

        if response is fhirClient:FHIRError {
            return error(string `Claim ${claimId} not found: ${response.message()}`);
        }

        return <json>response.'resource;
    }

    # Search ClaimResponses by organization
    #
    # + organizationId - Organization NPI
    # + return - Array of ClaimResponse resources or error
    public isolated function getClaimResponsesByOrg(string organizationId) returns json[]|error {
        // Search using extension filter for organization ID
        map<string[]> searchParams = {
            "insurer:identifier": [organizationId]
        };

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->search(
            "ClaimResponse",
            searchParameters = searchParams
        );

        if response is fhirClient:FHIRError {
            return error(string `Failed to search ClaimResponses: ${response.message()}`);
        }

        return self.extractResourcesFromBundle(<json>response.'resource);
    }

    # Add organization extension to ClaimResponse for filtering
    private isolated function addOrganizationExtension(json payload, string organizationId, string patientMemberId) returns json|error {
        map<json> payloadMap = check payload.cloneWithType();

        // Add meta profile if not present
        if !payloadMap.hasKey("meta") {
            payloadMap["meta"] = {};
        }

        // Add extension for organization tracking (useful for subscription filtering)
        json[] extensions = [];
        if payloadMap.hasKey("extension") {
            json existingExt = payloadMap.get("extension");
            if existingExt is json[] {
                extensions = existingExt;
            }
        }

        extensions.push({
            "url": "http://example.org/fhir/StructureDefinition/organization-identifier",
            "valueString": organizationId
        });
        extensions.push({
            "url": "http://example.org/fhir/StructureDefinition/patient-member-id",
            "valueString": patientMemberId
        });

        payloadMap["extension"] = extensions;

        return payloadMap.toJson();
    }

    # Extract organization ID from ClaimResponse extension
    private isolated function extractOrganizationId(json fhirResource) returns string|error {
        json|error extensions = fhirResource.extension;
        if extensions is json[] {
            foreach json ext in extensions {
                json|error url = ext.url;
                if url is string && url == "http://example.org/fhir/StructureDefinition/organization-identifier" {
                    json|error value = ext.valueString;
                    if value is string {
                        return value;
                    }
                }
            }
        }

        // Fallback: try to get from insurer reference identifier
        json|error insurer = fhirResource.insurer;
        if insurer is json {
            json|error identifier = insurer.identifier;
            if identifier is json {
                json|error value = identifier.value;
                if value is string {
                    return value;
                }
            }
        }

        return "";
    }

    # Convert FHIR resource to internal ClaimRecord format
    private isolated function toClaimRecord(json fhirResource) returns models:ClaimRecord|error {
        string claimResponseId = check fhirResource.id.ensureType();
        string organizationId = check self.extractOrganizationId(fhirResource);

        // Extract claim reference
        string claimId = "";
        json|error request = fhirResource.request;
        if request is json {
            json|error reference = request.reference;
            if reference is string {
                // Parse "Claim/xxx" format
                string[] parts = re `/`.split(reference);
                if parts.length() > 1 {
                    claimId = parts[1];
                }
            }
        }

        // Extract patient member ID from extension
        string patientMemberId = "";
        json|error extensions = fhirResource.extension;
        if extensions is json[] {
            foreach json ext in extensions {
                json|error url = ext.url;
                if url is string && url == "http://example.org/fhir/StructureDefinition/patient-member-id" {
                    json|error value = ext.valueString;
                    if value is string {
                        patientMemberId = value;
                    }
                }
            }
        }

        // Extract status/outcome
        string status = "";
        json|error outcome = fhirResource.outcome;
        if outcome is string {
            status = outcome;
        }

        return {
            claim_id: claimId,
            claimresponse_id: claimResponseId,
            organization_id: organizationId,
            patient_member_id: patientMemberId,
            status: status,
            payload: fhirResource,
            created_at: [0, 0],
            updated_at: [0, 0]
        };
    }

    # Extract resources from FHIR Bundle
    private isolated function extractResourcesFromBundle(json bundle) returns json[]|error {
        json[] resources = [];
        json|error entries = bundle.entry;

        if entries is json[] {
            foreach json entry in entries {
                json|error 'resource = entry.'resource;
                if 'resource is json {
                    resources.push('resource);
                }
            }
        }

        return resources;
    }
}
