// modules/repository/fhir_client.bal
// Azure FHIR Client Configuration and Initialization

import ballerinax/health.clients.fhir as fhirClient;

# Azure FHIR configuration parameters (read from Config.toml)
configurable string baseUrl = ?;
configurable string tokenUrl = ?;
configurable string clientId = ?;
configurable string clientSecret = ?;
configurable string[] scopes = ?;

# Get FHIR Connector configuration for Azure Health Data Services
#
# + return - FHIR Connector configuration
public isolated function getFhirConnectorConfig() returns fhirClient:FHIRConnectorConfig {
    return {
        baseURL: baseUrl,
        mimeType: fhirClient:FHIR_JSON,
        authConfig: {
            tokenUrl: tokenUrl,
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: scopes
        }
    };
}

# Initialize the FHIR Connector
#
# + return - FHIR Connector instance or error
public function initFhirConnector() returns fhirClient:FHIRConnector|error {
    fhirClient:FHIRConnectorConfig config = getFhirConnectorConfig();
    return new fhirClient:FHIRConnector(config);
}
