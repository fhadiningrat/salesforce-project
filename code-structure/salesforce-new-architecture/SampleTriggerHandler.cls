public class CaseConversationHandler {
    private static final String SYSTEM_ADMIN_PROFILE_NAME = 'System Administrator';
    private static final String PERMISSION_ERROR_MESSAGE = 'You do not have permission to create Case Conversations.';

    public static void handleBeforeInsert(List<CaseConversation__c> newConversations) {
        checkUserPermissions(newConversations);
        
        Set<Id> caseIds = new Set<Id>();
        for (CaseConversation__c conversation : newConversations) {
            caseIds.add(conversation.Case__c);
        }

        Map<Id, List<CaseConversation__c>> existingConversations = getExistingConversations(caseIds);
        Map<Id, String> caseTaxonomyMap = getCaseTaxonomy(caseIds);

        processConversations(newConversations, existingConversations, caseTaxonomyMap);
    }

    private static void checkUserPermissions(List<CaseConversation__c> conversations) {
        if (!UserInfo.getProfileId().equals([SELECT Id FROM Profile WHERE Name = :SYSTEM_ADMIN_PROFILE_NAME LIMIT 1].Id)) {
            for (CaseConversation__c conversation : conversations) {
                conversation.addError(PERMISSION_ERROR_MESSAGE);
            }
        }
    }

    private static Map<Id, List<CaseConversation__c>> getExistingConversations(Set<Id> caseIds) {
        Map<Id, List<CaseConversation__c>> conversationMap = new Map<Id, List<CaseConversation__c>>();
        for (CaseConversation__c existingConversation : [
            SELECT Id, IsLastConversation__c, IsLastOutbound__c, IsOutbound__c, Case__c 
            FROM CaseConversation__c 
            WHERE Case__c IN :caseIds
        ]) {
            if (!conversationMap.containsKey(existingConversation.Case__c)) {
                conversationMap.put(existingConversation.Case__c, new List<CaseConversation__c>());
            }
            conversationMap.get(existingConversation.Case__c).add(existingConversation);
        }
        return conversationMap;
    }

    private static Map<Id, String> getCaseTaxonomy(Set<Id> caseIds) {
        Map<Id, String> taxonomyMap = new Map<Id, String>();
        for (Case parentCase : [
            SELECT Id, Taxonomy__c FROM Case WHERE Id IN :caseIds
        ]) {
            taxonomyMap.put(parentCase.Id, parentCase.Taxonomy__c);
        }
        return taxonomyMap;
    }

    private static void processConversations(List<CaseConversation__c> conversations, 
                                             Map<Id, List<CaseConversation__c>> existingConversations, 
                                             Map<Id, String> caseTaxonomyMap) {
        for (CaseConversation__c conversation : conversations) {
            List<CaseConversation__c> existingList = existingConversations.get(conversation.Case__c);
            if (existingList == null || existingList.isEmpty()) {
                // This is the first CaseConversation for this Case
                conversation.IsLastConversation__c = true;
                if (conversation.IsOutbound__c) {
                    conversation.IsLastOutbound__c = true;
                }
            } else {
                // Not the first CaseConversation
                conversation.IsLastConversation__c = false;
                if (conversation.IsOutbound__c) {
                    conversation.IsLastOutbound__c = false;
                }
            }

            // If Inbound, set the Taxonomy based on the current Case
            if (!conversation.IsOutbound__c) {
                conversation.Taxonomy__c = caseTaxonomyMap.get(conversation.Case__c);
            }

            // Additional logic can be added here
            // For example, setting additional fields or performing validations
        }
    }

    public static void afterInsert(List<CaseConversation__c> newConversations) {
        // Separate outbound and inbound conversations
        List<CaseConversation__c> outboundConversations = new List<CaseConversation__c>();
        List<CaseConversation__c> inboundConversations = new List<CaseConversation__c>();
        Set<Id> caseIds = new Set<Id>();

        for (CaseConversation__c conversation : newConversations) {
            if (conversation.IsOutbound__c) {
                outboundConversations.add(conversation);
            } else {
                inboundConversations.add(conversation);
            }
            caseIds.add(conversation.Case__c);
        }

        // Query parent cases outside of the loop
        Map<Id, Case> parentCases = new Map<Id, Case>([SELECT Id, Status, Last_Solved_Time__c, AccountId, CountAgentReply__c, Taxonomy__c, InvoiceNo__c FROM Case WHERE Id IN :caseIds]);

        if (!outboundConversations.isEmpty()) {
            handleOutboundConversations(outboundConversations, parentCases);
        }

        if (!inboundConversations.isEmpty()) {
            handleInboundConversations(inboundConversations, parentCases);
        }
    }

    private static void handleOutboundConversations(List<CaseConversation__c> outboundConversations, Map<Id, Case> parentCases) {
        List<Case> casesToUpdate = new List<Case>();

        for (CaseConversation__c conversation : outboundConversations) {
            Case parentCase = parentCases.get(conversation.Case__c);
            if (parentCase != null) {
                parentCase.Status = 'Solved';
                parentCase.Last_Solved_Time__c = System.now();
                casesToUpdate.add(parentCase);

                // Validate UserID
                String userId = getUser IdFromAccount(parentCase.AccountId);
                if (isValidUser Id(userId)) {
                    // Continue processing
                } else {
                    createAccountInExternalSystem(userId);
                    updateMessageIdInSalesforceAccount(userId);
                }

                // Increment countAgentReply if created by Agent
                if (conversation.CreatedById != null && !isAutoReplyBot(conversation)) {
                    parentCase.CountAgentReply__c += 1;
                } else {
                    //getAutoReplyMessage
                    //insert conversation
                }

                // Handle different origins
                switch (conversation.Origin__c) {
                    case 'Slack':
                        sendToSlack(conversation);
                        break;
                    case 'Chatbot':
                        sendToChatbot(conversation);
                        break;
                    case 'Playstore':
                        sendToPlaystore(conversation);
                        break;
                    case 'AppStore':
                        sendToAppStore(conversation);
                        break;
                    case 'Web':
                        sendToContactApp(conversation);
                        break;
                }
            }
        }

        // Perform DML operation outside of the loop
        if (!casesToUpdate.isEmpty()) {
            update casesToUpdate;
        }
    }

    private static void handleInboundConversations(List<CaseConversation__c> inboundConversations, Map<Id, Case> parentCases) {
        List<Case> casesToUpdate = new List<Case>();
        List<Task> tasksToInsert = new List<Task>();
        List<CaseComment> commentsToInsert = new List<CaseComment>();

        for (CaseConversation__c conversation : inboundConversations) {
            Case parentCase = parentCases.get(conversation.Case__c);
            if (parentCase != null && isEligibleForAutoReply(parentCase)) {
                parentCase.Status = 'Solved';
                casesToUpdate.add(parentCase);

                // Handle bad words and complaints
                if (isHardComplaint(conversation)) {
                    Task followUpTask = new Task(
                        WhatId = parentCase.Id,
                        Subject = 'Follow Up',
                        Status = 'Not Started',
                        Priority = 'Normal',
                        ActivityDate = System.today().addMinutes(15)
                    );
                    tasksToInsert.add(followUpTask);

                    // Create a case comment as notes to the agent
                    CaseComment comment = new CaseComment(
                        ParentId = parentCase.Id,
                        CommentBody = 'This case requires a follow-up due to a hard complaint.'
                    );
                    commentsToInsert.add(comment);
                } else {
                    assignToQueue(parentCase);
                }

                // Handle invoice number
                handleInvoiceNumber(conversation, parentCase);
            }
        }

        // Perform DML operations outside of the loop
        if (!casesToUpdate.isEmpty()) {
            update casesToUpdate;
        }
        if (!tasksToInsert.isEmpty()) {
            insert tasksToInsert;
        }
        if (!commentsToInsert.isEmpty()) {
            insert commentsToInsert;
        }
    }

    private static void handleInvoiceNumber(CaseConversation__c conversation, Case parentCase) {
        // Logic to find and handle the invoice number using regex
        String invoicePattern = 'INV/(\\d{4})/(I|II|III|IV|V|VI|VII|VIII|IX|X)/(\\d+)';
        Pattern pattern = Pattern.compile(invoicePattern);
        Matcher matcher = pattern.matcher(conversation.Message__c);

        if (matcher.find()) {
            String invoiceNumber = matcher.group(0);
            // Check parent case for invoice number existence
            if (parentCase.InvoiceNo__c == null) {
                parentCase.InvoiceNo__c = invoiceNumber;
            } else if (parentCase.InvoiceNo__c != invoiceNumber) {
                // Create a case comment to notify the agent
                CaseComment comment = new CaseComment(
                    ParentId = parentCase.Id,
                    CommentBody = 'Invoice number mismatch detected. Existing: ' + parentCase.InvoiceNo__c + ', New: ' + invoiceNumber
                );
                insert comment;
            }
        }
    }

    private static String getUser IdFromAccount(Id accountId) {
        // Logic to get UserID from Account record
        // Placeholder: Implement the actual logic to retrieve UserID
        return ''; // Return the UserID
    }

    private static Boolean isValidUser Id(String userId) {
        // Logic to validate UserID with external system
        // Placeholder: Implement the actual validation logic
        return true; // Return true if valid, false otherwise
    }

    private static void createAccountInExternalSystem(String userId) {
        // Logic to create a new account in the external system
        // Placeholder: Implement the actual logic to create an account
    }

    private static void updateMessageIdInSalesforceAccount(String userId) {
        // Logic to update the message ID in Salesforce Account
        // Placeholder: Implement the actual logic to update the message ID
    }

    private static Boolean isAutoReplyBot(CaseConversation__c conversation) {
        // Logic to check if the conversation is created by an auto-reply bot
        // Placeholder: Implement the actual logic
        return false; // Return true if it's an auto-reply bot, false otherwise
    }

    private String getAutoReplyMessage(Case parentCase) {
        // Attempt to get the auto-reply template from Platform Cache
        String autoReplyName = parentCase.Auto_Reply_Name__c; // Assuming this field exists
        String autoReplyMessage = null;

        // Check if the auto-reply name is not blank
        if (String.isNotBlank(autoReplyName)) {
            autoReplyMessage = (String) Cache.Session.get('ReplyTemplate_' + autoReplyName);
        }

        // If no message found in cache, fall back to ReplyTemplate object
        if (String.isBlank(autoReplyMessage)) {
            ReplyTemplate template = [SELECT Body FROM ReplyTemplate WHERE Name = :autoReplyName LIMIT 1];
            if (template != null) {
                autoReplyMessage = template.Body;
            }
        }

        return autoReplyMessage;
    }

    private static void sendToSlack(CaseConversation__c conversation) {
        // Logic to send a message to Slack
        // Placeholder: Implement the actual logic to send a message
    }

    private static void sendToChatbot(CaseConversation__c conversation) {
        // Logic to send a message to Chatbot
        // Placeholder: Implement the actual logic to send a message
    }

    private static void sendToPlaystore(CaseConversation__c conversation) {
        // Logic to send a message to Playstore
        // Placeholder: Implement the actual logic to send a message
    }

    private static void sendToAppStore(CaseConversation__c conversation) {
        // Logic to send a message to App Store
        // Placeholder: Implement the actual logic to send a message
    }

    private static void sendToContactApp(CaseConversation__c conversation) {
        // Logic to send a message to the Contact App
        // Placeholder: Implement the actual logic to send a message
    }

    private static Boolean isEligibleForAutoReply(Case parentCase) {
        // Check if the case is eligible for auto-reply based on status and taxonomy
        if (parentCase.Status == 'Checking') {
            return true; // Auto-reply condition met
        }
        // Additional conditions can be added here
        return false;
    }

    private static Boolean isHardComplaint(CaseConversation__c conversation) {
        // Logic to check if the conversation contains hard complaints (bad words)
        // This could involve checking the message body for specific keywords
        return false; // Placeholder
    }

    private static void assignToQueue(Case parentCase) {
        // Logic to assign the case to a specific queue
        // This could involve setting the OwnerId to a queue Id
    }
}

// interface class
public interface IMessageSender {
    void send(CaseConversation__c conversation);
}

// concreate class
public class SlackSender implements IMessageSender {
    private static final String SLACK_WEBHOOK_URL = 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'; // Replace with your actual webhook URL

    public void send(ApiCallParameters parameters) {
        // Create the HTTP request
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SLACK_WEBHOOK_URL);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');

        // Create the payload
        String payload = JSON.serialize(new Map<String, Object>{
            'text' => parameters.message,
            'channel' => '#your-channel', // Specify the channel if needed
            'username' => 'Your Bot Name', // Optional: specify a username
            'icon_emoji' => ':robot_face:' // Optional: specify an emoji
        });

        req.setBody(payload);

        // Send the request
        Http http = new Http();
        HttpResponse res = http.send(req);

        // Handle the response (optional)
        if (res.getStatusCode() == 200) {
            System.debug('Message sent to Slack successfully: ' + res.getBody());
        } else {
            System.debug('Failed to send message to Slack: ' + res.getStatusCode() + ' - ' + res.getBody());
        }
    }
}

public class ChatbotSender implements IMessageSender {
    public void send(ApiCallParameters parameters) {
        // Logic to send message to Chatbot
        System.debug('Sending to Chatbot: ' + parameters.message);
        // Call the Chatbot API here with parameters
    }
}

// Repeat for other sender classes...

public class PlaystoreSender implements IMessageSender {
    public void send(CaseConversation__c conversation) {
        // Logic to send message to Playstore
        System.debug('Sending to Playstore: ' + conversation.Message__c);
    }
}

public class AppStoreSender implements IMessageSender {
    public void send(CaseConversation__c conversation) {
        // Logic to send message to AppStore
        System.debug('Sending to AppStore: ' + conversation.Message__c);
    }
}

public class WebSender implements IMessageSender {
    public void send(CaseConversation__c conversation) {
        // Logic to send message to Web
        System.debug('Sending to Web: ' + conversation.Message__c);
    }
}

// factory manager
public class MessageSenderFactory {
    public static IMessageSender getSender(String origin) {
        switch (origin) {
            case 'Slack':
                return new SlackSender();
            case 'Chatbot':
                return new ChatbotSender();
            case 'Playstore':
                return new PlaystoreSender();
            case 'AppStore':
                return new AppStoreSender();
            case 'Web':
                return new WebSender();
            default:
                throw new IllegalArgumentException('Unknown origin: ' + origin);
        }
    }
}

// // Handle different origins
IMessageSender sender = MessageSenderFactory.getSender(conversation.Origin__c);
sender.send(conversation);

// api call param
public class ApiCallParameters {
    public String message;
    public String origin;
    public String caseId;

    public ApiCallParameters(String message, String origin, String caseId) {
        this.message = message;
        this.origin = origin;
        this.caseId = caseId;
    }
}

// usage
List<ApiCallParameters> apiCallParamsList = new List<ApiCallParameters>();

for (CaseConversation__c conversation : conversations) {
    // Process the conversation and prepare parameters
    String message = conversation.Message__c;
    String origin = conversation.Origin__c;
    String caseId = conversation.Case__c;

    // Create parameters object
    ApiCallParameters params = new ApiCallParameters(message, origin, caseId);
    apiCallParamsList.add(params);
}

// Now make the API calls outside the loop
for (ApiCallParameters params : apiCallParamsList) {
    IMessageSender sender = MessageSenderFactory.getSender(params.origin);
    sender.send(params);
}