// modules/utils/fhir_utils.bal

import wso2/pas_payer_backend.models;
import ballerinax/health.fhir.r4;

# Extract NPIs from Claim resource
#
# + claim - Claim resource
# + return - Array of NPIs
public function extractNPIsFromClaim(models:Claim claim) returns string[] {
    string[] npis = [];

    // Extract provider NPI
    if claim.provider.identifier is models:Identifier {
        models:Identifier id = <models:Identifier>claim.provider.identifier;
        if id.value is string {
            npis.push(<string>id.value);
        }
    }

    // Extract careTeam NPIs
    // if claim.careTeam is models:ClaimCareTeam[] {
    //     foreach models:ClaimCareTeam member in <models:ClaimCareTeam[]>claim.careTeam {
    //         if member.provider.identifier is models:Identifier {
    //             models:Identifier id = <models:Identifier>member.provider.identifier;
    //             if id.value is string {
    //                 npis.push(<string>id.value);
    //             }
    //         }
    //     }
    // }

    return npis;
}

# Create OperationOutcome
#
# + severity - Severity level
# + code - Issue code
# + diagnostics - Diagnostic message
# + return - OperationOutcome
public function createOperationOutcome(
    string severity,
    string code,
    string diagnostics
) returns r4:OperationOutcome {
    return {
        resourceType: "OperationOutcome",
        issue: [
            {
                severity: <r4:OperationOutcomeIssueSeverity>severity,
                code: code,
                diagnostics: diagnostics
            }
        ]
    };
}

# Validate ClaimResponse status change
#
# + oldStatus - Previous status
# + newStatus - New status
# + return - True if valid transition
public function isValidStatusTransition(string oldStatus, string newStatus) returns boolean {
    // Pended to complete/partial is valid
    if (oldStatus == "pended" || oldStatus == "queued") &&
       (newStatus == "complete" || newStatus == "partial") {
        return true;
    }

    return false;
}
