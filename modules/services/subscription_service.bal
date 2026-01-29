// modules/services/subscription_service.bal

import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;
import ballerinax/health.fhir.r4.davincipas;

import wso2/pas_payer_backend.models;
import wso2/pas_payer_backend.repository;
import wso2/pas_payer_backend.utils;

# Subscription Management Service
public class SubscriptionService {
    private final repository:SubscriptionRepository subscriptionRepo;

    public function init(repository:SubscriptionRepository subscriptionRepo) {
        self.subscriptionRepo = subscriptionRepo;
    }

    # Create new subscription
    #
    # + subscription - PASSubscription resource
    # + return - Created subscription or error
    public function createSubscription(davincipas:PASSubscription subscription)
            returns davincipas:PASSubscription|error {

        // Extract organization ID from extensions
        string organizationId = check utils:extractOrganizationId(subscription);

        // Get endpoint from channel
        string endpoint = subscription.channel.endpoint ?: "";
        if endpoint == "" {
            return error("Subscription endpoint is required");
        }

        // Check if subscription already exists
        boolean exists = check self.subscriptionRepo.subscriptionExists(
            organizationId,
            endpoint
        );

        if exists {
            log:printInfo(string `Subscription already exists for org ${organizationId}`);
            return error("Subscription already exists");
        }

        // Generate subscription ID
        string subscriptionId = uuid:createType1AsString();

        // Create PASSubscription with generated ID
        davincipas:PASSubscription pasSubscription = subscription.clone();
        pasSubscription.id = subscriptionId;
        pasSubscription.status = davincipas:CODE_STATUS_REQUESTED;

        // Store in Azure FHIR
        _ = check self.subscriptionRepo.createSubscription(pasSubscription);

        // Send handshake
        boolean handshakeSuccess = check self.sendHandshake(subscriptionId, pasSubscription);

        davincipas:PASSubscriptionStatus finalStatus = handshakeSuccess
            ? davincipas:CODE_STATUS_ACTIVE
            : davincipas:CODE_STATUS_ERROR;

        check self.subscriptionRepo.updateStatus(subscriptionId, finalStatus);

        pasSubscription.status = finalStatus;
        pasSubscription.meta = {
            versionId: "1",
            lastUpdated: time:utcToString(time:utcNow())
        };

        return pasSubscription;
    }

    # Send handshake notification
    #
    # + subscriptionId - Subscription ID
    # + subscription - PASSubscription resource
    # + return - True if successful
    private function sendHandshake(
            string subscriptionId,
            davincipas:PASSubscription subscription
    ) returns boolean|error {

        string endpoint = subscription.channel.endpoint ?: "";
        if endpoint == "" {
            return error("Subscription endpoint is empty");
        }

        log:printInfo(string `Sending handshake to ${endpoint}`);

        // Build handshake bundle
        models:NotificationBundle bundle = {
            resourceType: "Bundle",
            'type: "history",
            timestamp: time:utcToString(time:utcNow()),
            entry: [
                {
                    fullUrl: string `urn:uuid:${uuid:createType1AsString()}`,
                    'resource: {
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
}
