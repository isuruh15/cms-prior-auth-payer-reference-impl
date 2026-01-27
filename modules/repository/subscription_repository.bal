// modules/repository/subscription_repository.bal
// Azure FHIR-based Subscription Repository

import ballerina/log;
import ballerinax/health.clients.fhir as fhirClient;
import wso2/pas_payer_backend.models;

# Subscription Repository for Azure FHIR Server operations
public isolated class SubscriptionRepository {
    private final fhirClient:FHIRConnector fhirConnector;

    # Initialize repository with FHIR Connector
    #
    # + fhirConnector - Azure FHIR Connector instance
    public isolated function init(fhirClient:FHIRConnector fhirConnector) {
        self.fhirConnector = fhirConnector;
    }

    # Create subscription in Azure FHIR Server
    #
    # + subscription - Subscription record to create
    # + return - Created subscription ID or error
    public isolated function createSubscription(models:SubscriptionRecord subscription)
            returns string|error {

        // Build FHIR Subscription resource
        json fhirSubscription = self.toFhirSubscription(subscription);

        // Create in Azure FHIR using conditional create
        map<string[]> condition = {"_id": [subscription.id]};

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->create(
            fhirSubscription,
            onCondition = condition
        );

        if response is fhirClient:FHIRError {
            log:printError(string `Failed to create subscription ${subscription.id}: ${response.message()}`);
            return error(string `Failed to create subscription: ${response.message()}`);
        }

        log:printInfo(string `Created subscription ${subscription.id} in Azure FHIR`);
        return subscription.id;
    }

    # Get subscription by ID from Azure FHIR Server
    #
    # + id - Subscription ID
    # + return - Subscription record or error
    public isolated function getSubscription(string id)
            returns models:SubscriptionRecord|error {

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->getById("Subscription", id);

        if response is fhirClient:FHIRError {
            return error(string `Subscription ${id} not found: ${response.message()}`);
        }

        return self.toSubscriptionRecord(<json>response.'resource);
    }

    # Get active subscriptions by organization ID from Azure FHIR Server
    #
    # + organizationId - Organization NPI
    # + return - Array of subscription records or error
    public isolated function getActiveSubscriptionsByOrg(string organizationId)
            returns models:SubscriptionRecord[]|error {

        // Search for active subscriptions with organization filter
        map<string[]> searchParams = {
            "status": ["active"],
            "criteria": [string `ClaimResponse?insurer:identifier=${organizationId}`]
        };

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->search(
            "Subscription",
            searchParameters = searchParams
        );

        if response is fhirClient:FHIRError {
            log:printError(string `Failed to search subscriptions: ${response.message()}`);
            return error(string `Failed to search subscriptions: ${response.message()}`);
        }

        return self.extractSubscriptionsFromBundle(<json>response.'resource, organizationId);
    }

    # Update subscription status in Azure FHIR Server
    #
    # + id - Subscription ID
    # + status - New status
    # + return - Error if operation fails
    public isolated function updateStatus(string id, string status) returns error? {
        // Get existing subscription
        fhirClient:FHIRResponse|fhirClient:FHIRError getResponse = self.fhirConnector->getById("Subscription", id);

        if getResponse is fhirClient:FHIRError {
            return error(string `Subscription ${id} not found: ${getResponse.message()}`);
        }

        // Update status field
        map<json> subscriptionMap = check getResponse.cloneWithType();
        subscriptionMap["status"] = status;

        // Update in Azure FHIR
        fhirClient:FHIRResponse|fhirClient:FHIRError updateResponse = self.fhirConnector->update(subscriptionMap.toJson());

        if updateResponse is fhirClient:FHIRError {
            log:printError(string `Failed to update subscription ${id}: ${updateResponse.message()}`);
            return error(string `Failed to update subscription: ${updateResponse.message()}`);
        }

        log:printInfo(string `Updated subscription ${id} to status ${status} in Azure FHIR`);
    }

    # Check if subscription exists for organization
    #
    # + organizationId - Organization NPI
    # + endpoint - Endpoint URL
    # + return - True if exists
    public isolated function subscriptionExists(string organizationId, string endpoint)
            returns boolean|error {

        // Search for existing subscription with same org and endpoint
        map<string[]> searchParams = {
            "status": ["active", "requested"],
            "url": [endpoint]
        };

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->search(
            "Subscription",
            searchParameters = searchParams
        );

        if response is fhirClient:FHIRError {
            // If search fails, assume no duplicate exists
            return false;
        }

        json bundle = <json>response.'resource;

        // Check if any results match the organization
        json|error total = bundle.total;
        if total is int && total > 0 {
            json|error entries = bundle.entry;
            if entries is json[] {
                foreach json entry in entries {
                    json|error 'resource = entry.'resource;
                    if 'resource is json {
                        string|error orgId = self.extractOrganizationFromSubscription('resource);
                        if orgId is string && orgId == organizationId {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    # Convert internal SubscriptionRecord to FHIR Subscription resource
    private isolated function toFhirSubscription(models:SubscriptionRecord subscription) returns json {
        // Build headers array
        json[] headers = [];
        if subscription.auth_header is string {
            headers.push(string `Authorization: ${<string>subscription.auth_header}`);
        }

        // Build filter criteria extension (R4 Backport)
        json criteriaExtension = {
            "url": "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-filter-criteria",
            "valueString": string `ClaimResponse?insurer:identifier=${subscription.organization_id}`
        };

        // Build payload content extension (R4 Backport)
        json payloadExtension = {
            "url": "http://hl7.org/fhir/uv/subscriptions-backport/StructureDefinition/backport-payload-content",
            "valueCode": subscription.payload_type
        };

        json fhirSubscription = {
            "resourceType": "Subscription",
            "id": subscription.id,
            "status": subscription.status,
            "reason": "ClaimResponse status change notifications",
            "criteria": "ClaimResponse?outcome:not=queued",
            "_criteria": [criteriaExtension],
            "channel": {
                "type": "rest-hook",
                "endpoint": subscription.endpoint,
                "payload": "application/fhir+json",
                "_payload": [payloadExtension],
                "header": headers
            },
            "extension": [
                {
                    "url": "http://example.org/fhir/StructureDefinition/organization-identifier",
                    "valueString": subscription.organization_id
                },
                {
                    "url": "http://example.org/fhir/StructureDefinition/failure-count",
                    "valueInteger": subscription.failure_count
                }
            ]
        };

        return fhirSubscription;
    }

    # Convert FHIR Subscription resource to internal SubscriptionRecord
    private isolated function toSubscriptionRecord(json fhirResource) returns models:SubscriptionRecord|error {
        string id = check fhirResource.id.ensureType();
        string status = check fhirResource.status.ensureType();

        // Extract endpoint from channel
        string endpoint = "";
        json|error channel = fhirResource.channel;
        if channel is json {
            json|error ep = channel.endpoint;
            if ep is string {
                endpoint = ep;
            }
        }

        // Extract auth header from channel headers
        string? authHeader = ();
        if channel is json {
            json|error headers = channel.header;
            if headers is json[] {
                foreach json header in headers {
                    if header is string && header.startsWith("Authorization:") {
                        authHeader = header.substring(15).trim();
                        break;
                    }
                }
            }
        }

        // Extract payload type from extension
        string payloadType = "full-resource";
        if channel is json {
            json|error payloadExt = channel._payload;
            if payloadExt is json[] {
                foreach json ext in payloadExt {
                    json|error url = ext.url;
                    if url is string && url.endsWith("backport-payload-content") {
                        json|error code = ext.valueCode;
                        if code is string {
                            payloadType = code;
                        }
                    }
                }
            }
        }

        // Extract organization ID from extension
        string organizationId = check self.extractOrganizationFromSubscription(fhirResource);

        // Extract failure count from extension
        int failureCount = 0;
        json|error extensions = fhirResource.extension;
        if extensions is json[] {
            foreach json ext in extensions {
                json|error url = ext.url;
                if url is string && url.endsWith("failure-count") {
                    json|error count = ext.valueInteger;
                    if count is int {
                        failureCount = count;
                    }
                }
            }
        }

        return {
            id: id,
            organization_id: organizationId,
            status: status,
            endpoint: endpoint,
            auth_header: authHeader,
            payload_type: payloadType,
            created_at: [0, 0],
            end_datetime: (),
            failure_count: failureCount
        };
    }

    # Extract organization ID from Subscription resource
    private isolated function extractOrganizationFromSubscription(json fhirResource) returns string|error {
        // First check extension
        json|error extensions = fhirResource.extension;
        if extensions is json[] {
            foreach json ext in extensions {
                json|error url = ext.url;
                if url is string && url.endsWith("organization-identifier") {
                    json|error value = ext.valueString;
                    if value is string {
                        return value;
                    }
                }
            }
        }

        // Fallback: try to parse from _criteria extension
        json|error criteriaExt = fhirResource._criteria;
        if criteriaExt is json[] {
            foreach json ext in criteriaExt {
                json|error url = ext.url;
                if url is string && url.endsWith("backport-filter-criteria") {
                    json|error criteria = ext.valueString;
                    if criteria is string {
                        // Parse "ClaimResponse?insurer:identifier=<orgId>"
                        int? eqIndex = criteria.indexOf("=");
                        if eqIndex is int {
                            return criteria.substring(eqIndex + 1);
                        }
                    }
                }
            }
        }

        return "";
    }

    # Extract subscriptions from FHIR Bundle with organization filter
    private isolated function extractSubscriptionsFromBundle(json bundle, string organizationId)
            returns models:SubscriptionRecord[]|error {

        models:SubscriptionRecord[] subscriptions = [];
        json|error entries = bundle.entry;

        if entries is json[] {
            foreach json entry in entries {
                json|error 'resource = entry.'resource;
                if 'resource is json {
                    // Extract organization and filter
                    string|error orgId = self.extractOrganizationFromSubscription('resource);
                    if orgId is string && orgId == organizationId {
                        models:SubscriptionRecord|error sub = self.toSubscriptionRecord('resource);
                        if sub is models:SubscriptionRecord {
                            subscriptions.push(sub);
                        }
                    }
                }
            }
        }

        return subscriptions;
    }
}
