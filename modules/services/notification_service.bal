// modules/services/notification_service.bal

import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/health.fhir.r4.davincipas;
import ballerinax/health.fhir.r4.international401;

import wso2/pas_payer_backend.models;
import wso2/pas_payer_backend.repository;
import wso2/pas_payer_backend.utils;

# Notification Service
public isolated class NotificationService {
    private final repository:SubscriptionRepository subscriptionRepo;

    public function init(repository:SubscriptionRepository subscriptionRepo) {
        self.subscriptionRepo = subscriptionRepo;
    }

    # Send notification for ClaimResponse update
    #
    # + claimResponseId - ClaimResponse ID
    # + organizationId - Organization ID
    # + claimResponse - Updated ClaimResponse
    # + return - Error if sending fails
    public isolated function sendNotifications(
            string claimResponseId,
            string organizationId,
            international401:ClaimResponse claimResponse
    ) returns error? {

        log:printInfo(string `Sending notifications for ClaimResponse ${claimResponseId}`);

        // Get active subscriptions
        davincipas:PASSubscription[] subscriptions =
            check self.subscriptionRepo.getActiveSubscriptionsByOrg(organizationId);

        if subscriptions.length() == 0 {
            log:printWarn(string `No active subscriptions for org ${organizationId}`);
            return;
        }

        // Send notification to each subscription
        foreach davincipas:PASSubscription sub in subscriptions {
            error? result = self.sendNotification(sub, claimResponseId, claimResponse);
            if result is error {
                log:printError(string `Failed to send notification to ${sub.id ?: "unknown"}: ${result.message()}`);
            }
        }
    }

    # Send notification to single subscription
    #
    # + subscription - PASSubscription resource
    # + claimResponseId - ClaimResponse ID
    # + claimResponse - ClaimResponse resource
    # + return - Error if sending fails
    private isolated function sendNotification(
            davincipas:PASSubscription subscription,
            string claimResponseId,
            international401:ClaimResponse claimResponse
    ) returns error? {

        // Get endpoint from channel
        string endpoint = subscription.channel.endpoint ?: "";
        if endpoint == "" {
            return error("Subscription endpoint is empty");
        }

        // Build notification bundle
        models:NotificationBundle bundle = check self.buildNotificationBundle(
            subscription,
            claimResponseId,
            claimResponse
        );

        // Send HTTP POST
        http:Client httpClient = check new (endpoint, {
            timeout: 30,
            retryConfig: {
                count: 3,
                interval: 2
            }
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
                log:printInfo(string `Notification sent successfully to ${endpoint}`);
                return;
            } else {
                return error(string `HTTP ${response.statusCode}`);
            }
        } else {
            return error(string `HTTP error: ${response.message()}`);
        }
    }

    # Build notification bundle
    #
    # + subscription - PASSubscription resource
    # + claimResponseId - ClaimResponse ID
    # + claimResponse - ClaimResponse resource
    # + return - Notification bundle
    private isolated function buildNotificationBundle(
            davincipas:PASSubscription subscription,
            string claimResponseId,
            international401:ClaimResponse claimResponse
    ) returns models:NotificationBundle|error {

        string subscriptionId = subscription.id ?: "";
        string bundleId = string `notification-${time:utcNow()[0]}`;
        string statusId = string `status-${time:utcNow()[0]}`;

        // Build SubscriptionStatus as Parameters (R4)
        models:SubscriptionStatusParameters statusParams = {
            resourceType: "Parameters",
            id: statusId,
            'parameter: [
                {
                    name: "subscription",
                    valueReference: {
                        reference: string `Subscription/${subscriptionId}`
                    }
                },
                {
                    name: "topic",
                    valueCanonical: "http://hl7.org/fhir/us/davinci-pas/SubscriptionTopic/PASSubscriptionTopic"
                },
                {
                    name: "status",
                    valueCode: subscription.status
                },
                {
                    name: "type",
                    valueCode: "event-notification"
                },
                {
                    name: "notification-event",
                    part: [
                        {
                            name: "event-number",
                            valueString: "1"
                        },
                        {
                            name: "timestamp",
                            valueInstant: time:utcToString(time:utcNow())
                        },
                        {
                            name: "focus",
                            valueReference: {
                                reference: string `ClaimResponse/${claimResponseId}`
                            }
                        }
                    ]
                }
            ]
        };

        models:NotificationBundleEntry[] entries = [
            {
                fullUrl: string `urn:uuid:${statusId}`,
                'resource: statusParams.toJson(),
                request: {
                    method: "GET",
                    url: string `Subscription/${subscriptionId}/$status`
                },
                response: {
                    status: "200"
                }
            }
        ];

        // Add ClaimResponse if full-resource payload
        string payloadType = utils:extractPayloadType(subscription);
        if payloadType == "full-resource" {
            entries.push({
                fullUrl: string `ClaimResponse/${claimResponseId}`,
                'resource: claimResponse.toJson(),
                request: {
                    method: "PUT",
                    url: string `ClaimResponse/${claimResponseId}`
                },
                response: {
                    status: "200"
                }
            });
        }

        models:NotificationBundle bundle = {
            resourceType: "Bundle",
            id: bundleId,
            'type: "history",
            timestamp: time:utcToString(time:utcNow()),
            entry: entries
        };

        return bundle;
    }
}
