// modules/repository/subscription_repository.bal
// Azure FHIR-based Subscription Repository

import ballerina/log;
import ballerinax/health.clients.fhir as fhirClient;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.davincipas;

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
    # + subscription - PASSubscription resource to create
    # + return - Created subscription ID or error
    public isolated function createSubscription(davincipas:PASSubscription subscription)
            returns string|error {

        // Convert to JSON for FHIR connector
        json fhirSubscription = subscription.toJson();

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->create(
            fhirSubscription
        );

        if response is fhirClient:FHIRError {
            log:printError(string `Failed to create subscription ${subscription.id ?: "unknown"}: ${response.message()}`);
            return error(string `Failed to create subscription: ${response.message()}`);
        }

        log:printInfo(string `Created subscription ${subscription.id ?: "unknown"} in Azure FHIR`);
        return subscription.id ?: "";
    }

    # Get subscription by ID from Azure FHIR Server
    #
    # + id - Subscription ID
    # + return - PASSubscription resource or error
    public isolated function getSubscription(string id)
            returns davincipas:PASSubscription|error {

        fhirClient:FHIRResponse|fhirClient:FHIRError response = self.fhirConnector->getById("Subscription", id);

        if response is fhirClient:FHIRError {
            return error(string `Subscription ${id} not found: ${response.message()}`);
        }

        return self.toPASSubscription(<json>response.'resource);
    }

    # Get active subscriptions by organization ID from Azure FHIR Server
    #
    # + organizationId - Organization NPI
    # + return - Array of PASSubscription resources or error
    public isolated function getActiveSubscriptionsByOrg(string organizationId)
            returns davincipas:PASSubscription[]|error {

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

    # Convert FHIR JSON resource to PASSubscription
    private isolated function toPASSubscription(json fhirResource) returns davincipas:PASSubscription|error {
        string id = check fhirResource.id.ensureType();
        string statusStr = check fhirResource.status.ensureType();
        string reason = "";
        string criteria = "";

        json|error reasonJson = fhirResource.reason;
        if reasonJson is string {
            reason = reasonJson;
        }

        json|error criteriaJson = fhirResource.criteria;
        if criteriaJson is string {
            criteria = criteriaJson;
        }

        // Extract channel
        davincipas:PASSubscriptionChannel channel = {
            'type: davincipas:CODE_TYPE_REST_HOOK
        };

        json|error channelJson = fhirResource.channel;
        if channelJson is json {
            json|error ep = channelJson.endpoint;
            if ep is string {
                channel.endpoint = ep;
            }

            json|error channelType = channelJson.'type;
            if channelType is string {
                channel.'type = <davincipas:PASSubscriptionChannelType>channelType;
            }

            json|error payloadJson = channelJson.payload;
            if payloadJson is string {
                channel.payload = <davincipas:PASSubscriptionChannelPayload>payloadJson;
            }

            json|error headers = channelJson.header;
            if headers is json[] {
                string[] headerArr = [];
                foreach json header in headers {
                    if header is string {
                        headerArr.push(header);
                    }
                }
                channel.header = headerArr;
            }
        }

        // Extract extensions
        r4:Extension[] extensions = [];
        json|error extJson = fhirResource.extension;
        if extJson is json[] {
            foreach json ext in extJson {
                json|error url = ext.url;
                json|error valueString = ext.valueString;
                json|error valueInteger = ext.valueInteger;

                string extUrl = url is string ? url : "";

                if valueString is string {
                    r4:StringExtension strExt = {
                        url: extUrl,
                        valueString: valueString
                    };
                    extensions.push(strExt);
                } else if valueInteger is int {
                    r4:IntegerExtension intExt = {
                        url: extUrl,
                        valueInteger: valueInteger
                    };
                    extensions.push(intExt);
                }
            }
        }

        davincipas:PASSubscription subscription = {
            id: id,
            status: <davincipas:PASSubscriptionStatus>statusStr,
            reason: reason,
            criteria: criteria,
            channel: channel
        };

        if extensions.length() > 0 {
            subscription.extension = extensions;
        }

        return subscription;
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
            returns davincipas:PASSubscription[]|error {

        davincipas:PASSubscription[] subscriptions = [];
        json|error entries = bundle.entry;

        if entries is json[] {
            foreach json entry in entries {
                json|error 'resource = entry.'resource;
                if 'resource is json {
                    // Extract organization and filter
                    string|error orgId = self.extractOrganizationFromSubscription('resource);
                    if orgId is string && orgId == organizationId {
                        davincipas:PASSubscription|error sub = self.toPASSubscription('resource);
                        if sub is davincipas:PASSubscription {
                            subscriptions.push(sub);
                        }
                    }
                }
            }
        }

        return subscriptions;
    }
}
