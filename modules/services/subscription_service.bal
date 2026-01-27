// modules/services/subscription_service.bal

import ballerina/uuid;
import ballerina/time;
import ballerina/log;
import ballerina/http;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.international401;
import wso2/pas_payer_backend.models;
import wso2/pas_payer_backend.repository;

# Subscription Management Service
public class SubscriptionService {
    private final repository:SubscriptionRepository subscriptionRepo;

    public function init(repository:SubscriptionRepository subscriptionRepo) {
        self.subscriptionRepo = subscriptionRepo;
    }

    # Create new subscription
    #
    # + subscription - Subscription resource
    # + return - Created subscription or error
    public function createSubscription(international401:Subscription subscription)
            returns international401:Subscription|error {

        // Extract organization ID from filter criteria extension
        string organizationId = check self.extractOrganizationId(subscription);

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

        // Extract payload type from channel extension
        string payloadType = self.extractPayloadType(subscription);

        // Extract auth header
        string? authHeader = self.extractAuthHeader(subscription);

        // Parse end datetime
        time:Utc? endDateTime = ();
        if subscription.end is r4:instant {
            endDateTime = check time:utcFromString(<string>subscription.end);
        }

        // Create subscription record
        models:SubscriptionRecord subRecord = {
            id: subscriptionId,
            organization_id: organizationId,
            status: "requested",
            endpoint: endpoint,
            auth_header: authHeader,
            payload_type: payloadType,
            created_at: time:utcNow(),
            end_datetime: endDateTime,
            failure_count: 0
        };

        // Store in database
        _ = check self.subscriptionRepo.createSubscription(subRecord);

        // Send handshake
        boolean handshakeSuccess = check self.sendHandshake(subscriptionId, subRecord);

        // Clone the subscription to make it mutable for updates
        international401:Subscription result = subscription.clone();

        if handshakeSuccess {
            check self.subscriptionRepo.updateStatus(subscriptionId, "active");
            result.status = international401:CODE_STATUS_ACTIVE;
        } else {
            check self.subscriptionRepo.updateStatus(subscriptionId, "error");
            result.status = international401:CODE_STATUS_ERROR;
        }

        result.id = subscriptionId;
        result.meta = {
            versionId: "1",
            lastUpdated: time:utcToString(time:utcNow())
        };

        return result;
    }

    # Extract organization ID from subscription extension
    #
    # + subscription - Subscription resource
    # + return - Organization ID or error
    private function extractOrganizationId(international401:Subscription subscription)
            returns string|error {

        r4:Extension[]? extensions = subscription.extension;
        if extensions is () {
            return error("Filter criteria extension is required");
        }

        foreach r4:Extension ext in extensions {
            if ext.url.includes("backport-filter-criteria") && ext is r4:StringExtension {
                string? valueStr = ext.valueString;
                if valueStr is string {
                    string[] parts = re `=`.split(valueStr);
                    if parts.length() == 2 && parts[0] == "org-identifier" {
                        return parts[1];
                    }
                }
            }
        }

        return error("org-identifier filter not found");
    }

    # Extract payload type from channel extension
    #
    # + subscription - Subscription resource
    # + return - Payload type
    private function extractPayloadType(international401:Subscription subscription)
            returns string {

        r4:Extension[]? channelExtensions = subscription.channel.extension;
        if channelExtensions is r4:Extension[] {
            foreach r4:Extension ext in channelExtensions {
                if ext.url.includes("backport-payload-content") && ext is r4:CodeExtension {
                    r4:code? valueCode = ext.valueCode;
                    if valueCode is r4:code {
                        return valueCode;
                    }
                }
            }
        }

        return "empty";
    }

    # Extract authorization header
    #
    # + subscription - Subscription resource
    # + return - Auth header or null
    private function extractAuthHeader(international401:Subscription subscription)
            returns string? {

        string[]? headers = subscription.channel.header;
        if headers is string[] {
            foreach string header in headers {
                if header.startsWith("Authorization:") {
                    return header;
                }
            }
        }

        return ();
    }

    # Send handshake notification
    #
    # + subscriptionId - Subscription ID
    # + subRecord - Subscription record
    # + return - True if successful
    private function sendHandshake(
        string subscriptionId,
        models:SubscriptionRecord subRecord
    ) returns boolean|error {

        log:printInfo(string `Sending handshake to ${subRecord.endpoint}`);

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
        http:Client httpClient = check new (subRecord.endpoint, {
            timeout: 10
        });

        map<string|string[]> headers = {
            "Content-Type": "application/fhir+json"
        };

        if subRecord.auth_header is string {
            string authValue = (<string>subRecord.auth_header).substring(15);
            headers["Authorization"] = authValue;
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
