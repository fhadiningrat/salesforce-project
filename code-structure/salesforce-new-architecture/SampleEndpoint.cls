@RestResource(urlMapping='/chatbot/inbound')
global with sharing class ChatbotInboundEndpoint {
    @HttpPost
    global static String handlePost(String requestBody) {
        // Start time for logging
        Long startTime = System.currentTimeMillis();
        String response;

        try {
            // Parse the incoming JSON request
            Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            // Validate and process the request
            ChatbotRequestProcessor processor = new ChatbotRequestProcessor();
            response = processor.processRequest(params);
        } catch (Exception e) {
            response = JSON.serialize(new Map<String, String>{
                'error' => 'Internal Server Error',
                'message' => e.getMessage()
            });
        } finally {
            // Log the request details
            LogRequestHandler.logRequest(requestBody, startTime, response);
        }

        return response;
    }



    // validator
    public class ParameterValidator {
        public static void validateParameters(Map<String, Object> params) {
            // Mandatory parameters
            List<String> mandatoryParams = new List<String>{'ChatbotId', 'userId', 'message'};
            for (String param : mandatoryParams) {
                if (!params.containsKey(param) || String.isBlank((String) params.get(param))) {
                    throw new IllegalArgumentException(param + ' is mandatory.');
                }
            }

            // Validate mandatory parameters
            String customerType = (String) params.get('customerType');
            if (String.isEmpty(customerType) || !(customerType == 'Buyer' || customerType == 'Seller')) {
                throw new IllegalArgumentException('Invalid customer type. Must be "Buyer" or "Seller".');
            }

            // Validate optional customer tier
            String customerTier = (String) params.get('customerTier');
            if (customerTier != null) {
                List<String> validTiers = new List<String>{'Silver', 'Gold', 'Diamond'};
                if (!validTiers.contains(customerTier)) {
                    throw new IllegalArgumentException('Invalid customer tier. Valid options are: Silver, Gold, Diamond.');
                }
            }
        }

        public static String escapeSingleQuotes(String input) {
            return input.replace('\'', '\\\'');
        }
    }

    // usermanager
    public class UserManager {
        public static Id getOrCreateUser (String userId, String customerName, String customerEmail, String customerPhone) {
            // Check if user exists
            List<User> users = [SELECT Id FROM User WHERE UserId__c = :userId LIMIT 1];
            if (!users.isEmpty()) {
                return users[0].Id;
            } else {
                // Create new user
                User newUser  = new User();
                newUser .UserId__c = userId;
                newUser .Name = customerName;
                newUser .Email = customerEmail;
                newUser .Phone = customerPhone;
                insert newUser ;
                return newUser .Id;
            }
        }
    }

    // case manager
    public class CaseManager {
        public static Id getOrCreateCase(Id caseId, Id accountId, String customerType, String customerTier, Map<String, Object> invoiceDetails) {
            Case newCase;

            if (caseId != null) {
                // Fetch existing case
                newCase = [SELECT Id, Subject, Status FROM Case WHERE Id = :caseId LIMIT 1];
            } else {
                // Create a new case
                newCase = new Case();
                newCase.AccountId = accountId;
                newCase.Type = customerType; // Set customer type
                newCase.Customer_Tier__c = customerTier; // Set customer tier (custom field)

                // Optionally, add invoice details to the case description or custom fields
                if (invoiceDetails != null) {
                    newCase.Description = 'Invoice Details: ' + JSON.serialize(invoiceDetails);
                    // You can also set specific fields based on the invoice details
                    // newCase.Product_Details__c = (String) invoiceDetails.get('products');
                    // newCase.Order_Details__c = (String) invoiceDetails.get('orderDetails');
                    // newCase.Payment_Info__c = (String) invoiceDetails.get('paymentInfo');
                }

                // Insert the new case
                insert newCase;
            }

            return newCase.Id; // Return the case ID
        }

        public static void addCaseComment(Id caseId, String comment) {
            // Create a new case comment
            CaseComment caseComment = new CaseComment();
            caseComment.ParentId = caseId; // Link the comment to the case
            caseComment.CommentBody = comment; // Set the comment body
            caseComment.IsPublished = true; // Publish the comment

            // Insert the case comment
            insert caseComment;
        }
    }

    // logging class
    public class LogRequestHandler {
        public static void logRequest(String requestBody, Long startTime, String response) {
            Log__c logEntry = new Log__c();
            logEntry.Request_Body__c = requestBody;
            logEntry.Start_Time__c = startTime;
            logEntry.Status__c = response.contains('error') ? 'Failed' : 'Success';
            logEntry.Error_Message__c = response.contains('error') ? response : null;
            logEntry.Duration__c = System.currentTimeMillis() - startTime;
            insert logEntry;
        }
    }

    // processor
    public class ChatbotRequestProcessor {
        public String processRequest(Map<String, Object> params) {
            // Validate all parameters
            ParameterValidator.validateParameters(params);

            // Extract parameters after validation
            String invoice = (String) params.get('Invoice');
            String customerType = (String) params.get('customerType'); // Mandatory
            String customerTier = (String) params.get('customerTier'); // Optional

            // Fetch invoice details if invoice exists
            Map<String, Object> invoiceDetails = new Map<String, Object>();
            if (invoice != null) {
                invoiceDetails = InvoiceService.fetchInvoiceDetails(invoice);
                if (invoiceDetails == null) {
                    // Log the failure and add a comment to the case
                    System.debug('Invoice fetching failed for Invoice ID: ' + invoice);
                }
            }

            // Continue with the rest of the processing
            // Get or create user
            Id accountId = UserManager.getOrCreateUser (userId, customerName, customerEmail, customerPhone);

            // Get or create case
            Id newCaseId = CaseManager.getOrCreateCase(caseId, accountId, customerType, customerTier, invoiceDetails);

            // If invoice details were not fetched, add a comment to the case
            if (invoiceDetails == null) {
                CaseManager.addCaseComment(newCaseId, 'Failed to fetch invoice details for Invoice ID: ' + invoice);
            }

            // Insert CaseConversation
            CaseConversation__c conversation = new CaseConversation__c();
            conversation.Parent_Case__c = newCaseId;
            conversation.Message__c = message;
            conversation.ChatbotId__c = chatbotId;
            conversation.UUID__c = uuID;
            insert conversation;

            // Return success response
            return JSON.serialize(new Map<String, String>{
                'success' => 'true',
                'message' => 'Conversation successfully recorded.',
                'caseId' => newCaseId,
                'conversationId' => conversation.Id
            });
        }
    }

    // validatoin uuID
    public class CaseConversation {
        public static Boolean existsWithUUID(String uuID) {
            List<CaseConversation__c> conversations = [SELECT Id FROM CaseConversation__c WHERE UUID__c = :uuID LIMIT 1];
            return !conversations.isEmpty();
        }
    }

    // invoice service
    public class InvoiceService {
        public static Map<String, Object> fetchInvoiceDetails(String invoiceId) {
            // Initialize a map to hold the invoice details
            Map<String, Object> invoiceDetails = new Map<String, Object>();

            // Construct the API endpoint URL (this is a placeholder; replace with your actual endpoint)
            String apiUrl = 'https://api.example.com/invoices/' + invoiceId;

            // Create an HTTP request
            HttpRequest req = new HttpRequest();
            req.setEndpoint(apiUrl);
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            // Add any necessary authentication headers
            req.setHeader('Authorization', 'Bearer ' + 'YOUR_ACCESS_TOKEN');

            // Send the request
            Http http = new Http();
            HttpResponse res;
            try {
                res = http.send(req);
            } catch (Exception e) {
                // Log the error
                System.debug('Error fetching invoice details: ' + e.getMessage());
                return null; // Return null to indicate failure
            }

            // Check the response status
            if (res.getStatusCode() == 200) {
                // Parse the response body
                invoiceDetails = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            } else {
                // Log the error response
                System.debug('Failed to fetch invoice details. Status: ' + res.getStatusCode() + ', Response: ' + res.getBody());
                return null; // Return null to indicate failure
            }

            return invoiceDetails; // Return the fetched invoice details
        }
    }
}