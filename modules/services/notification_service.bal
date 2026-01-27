// modules/services/notification_service.bal

import ballerina/log;
import ballerina/time;
import ballerina/http;
import wso2/pas_payer_backend.models;
import wso2/pas_payer_backend.repository;

# Notification Service
public class NotificationService {
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
    public function sendNotifications(
        string claimResponseId,
        string organizationId,
        models:ClaimResponse claimResponse
    ) returns error? {
        
        log:printInfo(string `Sending notifications for ClaimResponse ${claimResponseId}`);

        // Get active subscriptions
        models:SubscriptionRecord[] subscriptions = 
            check self.subscriptionRepo.getActiveSubscriptionsByOrg(organizationId);

        if subscriptions.length() == 0 {
            log:printWarn(string `No active subscriptions for org ${organizationId}`);
            return;
        }

        // Send notification to each subscription
        foreach models:SubscriptionRecord sub in subscriptions {
            error? result = self.sendNotification(sub, claimResponseId, claimResponse);
            if result is error {
                log:printError(string `Failed to send notification to ${sub.id}: ${result.message()}`);
            }
        }
    }

    # Send notification to single subscription
    #
    # + subscription - Subscription record
    # + claimResponseId - ClaimResponse ID
    # + claimResponse - ClaimResponse resource
    # + return - Error if sending fails
    private function sendNotification(
        models:SubscriptionRecord subscription,
        string claimResponseId,
        models:ClaimResponse claimResponse
    ) returns error? {
        
        // Build notification bundle
        models:NotificationBundle bundle = check self.buildNotificationBundle(
            subscription,
            claimResponseId,
            claimResponse
        );

        // Send HTTP POST
        http:Client httpClient = check new (subscription.endpoint, {
            timeout: 30,
            retryConfig: {
                count: 3,
                interval: 2
            }
        });

        map<string|string[]> headers = {
            "Content-Type": "application/fhir+json"
        };

        if subscription.auth_header is string {
            string authValue = (<string>subscription.auth_header).substring(15);
            headers["Authorization"] = authValue;
        }

        http:Response|error response = httpClient->post("/", bundle, headers);

        if response is http:Response {
            if response.statusCode >= 200 && response.statusCode < 300 {
                log:printInfo(string `Notification sent successfully to ${subscription.endpoint}`);
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
    # + subscription - Subscription record
    # + claimResponseId - ClaimResponse ID
    # + claimResponse - ClaimResponse resource
    # + return - Notification bundle
    private function buildNotificationBundle(
        models:SubscriptionRecord subscription,
        string claimResponseId,
        models:ClaimResponse claimResponse
    ) returns models:NotificationBundle|error {
        
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
                        reference: string `Subscription/${subscription.id}`
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
                    url: string `Subscription/${subscription.id}/$status`
                },
                response: {
                    status: "200"
                }
            }
        ];

        // Add ClaimResponse if full-resource payload
        if subscription.payload_type == "full-resource" {
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
