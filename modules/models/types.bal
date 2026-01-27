// modules/models/types.bal
// Re-export standard FHIR R4 types from Ballerina Central packages

import ballerina/time;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.international401;

// ============================================================================
// Re-exported FHIR Resource Types from international401
// ============================================================================

# FHIR Claim resource type
public type Claim international401:Claim;

# FHIR ClaimResponse resource type
public type ClaimResponse international401:ClaimResponse;

# FHIR Subscription resource type
public type Subscription international401:Subscription;

# FHIR SubscriptionChannel type
public type SubscriptionChannel international401:SubscriptionChannel;

// ============================================================================
// Re-exported FHIR Base Types from r4
// ============================================================================

# FHIR Meta type
public type Meta r4:Meta;

# FHIR Reference type
public type Reference r4:Reference;

# FHIR Identifier type
public type Identifier r4:Identifier;

# FHIR CodeableConcept type
public type CodeableConcept r4:CodeableConcept;

# FHIR Coding type
public type Coding r4:Coding;

# FHIR Extension type
public type Extension r4:Extension;

# FHIR Period type
public type Period r4:Period;

# FHIR Bundle type
public type Bundle r4:Bundle;

# FHIR BundleEntry type
public type BundleEntry r4:BundleEntry;

# FHIR OperationOutcome type
public type OperationOutcome r4:OperationOutcome;

# FHIR Parameters type
public type Parameters r4:Parameters;

# FHIR ParametersParameter type
public type ParametersParameter r4:ParametersParameter;

// ============================================================================
// Internal Database Models (non-FHIR)
// ============================================================================

# Internal record for storing claim data
public type ClaimRecord record {|
    string claim_id;
    string claimresponse_id;
    string organization_id;
    string patient_member_id;
    string status;
    json payload;
    time:Utc created_at;
    time:Utc updated_at;
|};

# Internal record for storing subscription data
public type SubscriptionRecord record {|
    string id;
    string organization_id;
    string status;
    string endpoint;
    string? auth_header;
    string payload_type;
    time:Utc created_at;
    time:Utc? end_datetime;
    int failure_count;
|};

# Notification event for internal processing
public type NotificationEvent record {|
    string subscriptionId;
    string claimResponseId;
    string organizationId;
    string eventType; // handshake | event-notification | heartbeat
    time:Utc timestamp;
    json? payload;
|};

// ============================================================================
// Notification Bundle Types (R4 Backport specific)
// ============================================================================

# Notification Bundle for FHIR R4 Subscription Backport
public type NotificationBundle record {
    string resourceType = "Bundle";
    string id?;
    Meta meta?;
    string 'type; // history
    string timestamp;
    NotificationBundleEntry[] entry;
};

# Bundle entry for notification
public type NotificationBundleEntry record {
    string fullUrl?;
    json? 'resource?;
    BundleRequest? request?;
    BundleResponse? response?;
};

# Bundle request element
public type BundleRequest record {
    string method;
    string url;
};

# Bundle response element
public type BundleResponse record {
    string status;
    string location?;
};

# SubscriptionStatus as Parameters (R4 Backport)
public type SubscriptionStatusParameters record {
    string resourceType = "Parameters";
    string id?;
    Meta meta?;
    SubscriptionStatusParameter[] 'parameter;
};

# Parameter entry for SubscriptionStatus
public type SubscriptionStatusParameter record {
    string name;
    string? valueString?;
    string? valueCode?;
    string? valueInstant?;
    Reference? valueReference?;
    string? valueCanonical?;
    SubscriptionStatusParameter[]? part?;
};
