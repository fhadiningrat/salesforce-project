global class ConversationBatch implements Database.Batchable<SObject>, Database.Stateful {
    global Integer totalRecordsProcessed = 0;
    global Integer successfulRecords = 0;
    global Integer failedRecords = 0;
    global List<String> errorMessages = new List<String>();

    global Database.QueryLocator start(Database.BatchableContext BC) {
        return Database.getQueryLocator([
            SELECT Id, CreatedDate, Last_Chat__c, Outbound__c, Parent_Case__c
            FROM Conversation__c
            WHERE CreatedDate <= :System.now().addDays(-3)
            AND Last_Chat__c = TRUE
            AND Outbound__c = TRUE
        ]);
    }

    global void execute(Database.BatchableContext BC, List<Conversation__c> scope) {
        // Collect parent case IDs to query them in bulk
        Set<Id> parentCaseIds = new Set<Id>();
        for (Conversation__c conversation : scope) {
            totalRecordsProcessed++;
            if (conversation.Parent_Case__c != null) {
                parentCaseIds.add(conversation.Parent_Case__c);
            }
        }

        // Query all parent cases in one go
        Map<Id, Case> parentCasesMap = new Map<Id, Case>([
            SELECT Id, Status FROM Case WHERE Id IN :parentCaseIds
        ]);

        // Prepare lists for DML operations
        List<Case> casesToUpdate = new List<Case>();
        List<Conversation__c> conversationsToInsert = new List<Conversation__c>();
        List<Batch_Log__c> logsToInsert = new List<Batch_Log__c>();

        for (Conversation__c conversation : scope) {
            try {
                if (conversation.Parent_Case__c != null && parentCasesMap.containsKey(conversation.Parent_Case__c)) {
                    Case parentCase = parentCasesMap.get(conversation.Parent_Case__c);
                    if (parentCase.Status == 'Solved') {
                        // Call external API to check invoice status
                        String invoiceStatus = InvoiceService.checkInvoiceStatus(conversation.Id);
                        if (invoiceStatus == 'Delivered') {
                            // Update case to closed
                            parentCase.Status = 'Closed';
                            casesToUpdate.add(parentCase);

                            // Create a new conversation to reply to the chatbot
                            Conversation__c newConversation = new Conversation__c();
                            newConversation.Parent_Case__c = parentCase.Id;
                            newConversation.Message__c = 'Your order has been delivered and the case is now closed.';
                            conversationsToInsert.add(newConversation);

                            successfulRecords++;
                        }
                    }
                }
            } catch (Exception e) {
                failedRecords++;
                String errorMessage = 'Error processing conversation ID ' + conversation.Id + ': ' + e.getMessage();
                errorMessages.add(errorMessage);

                // Log the error to the custom log object
                Batch_Log__c log = new Batch_Log__c();
                log.Batch_Name__c = 'ConversationBatch';
                log.Record_Id__c = conversation.Id;
                log.Error_Message__c = errorMessage;
                logsToInsert.add(log);
            }
        }

        // Perform DML operations outside of the loop
        if (!casesToUpdate.isEmpty()) {
            update casesToUpdate;
        }
        if (!conversationsToInsert.isEmpty()) {
            insert conversationsToInsert;
        }
        if (!logsToInsert.isEmpty()) {
            insert logsToInsert; // Log errors if any
        }
    }

    global void finish(Database.BatchableContext BC) {
        EmailNotificationService.sendBatchCompletionEmail(totalRecordsProcessed, successfulRecords, failedRecords, errorMessages);
    }



// // Invoice Service Class
public class InvoiceService {
    public static String checkInvoiceStatus(Id conversationId) {
        // Implement the logic to call the external API and return the invoice status
        // This is a placeholder implementation
        return 'Delivered'; // Replace with actual API call logic
    }
}

// Email Notification Service Class
public class EmailNotificationService {
    public static void sendBatchCompletionEmail(Integer totalProcessed, Integer successful, Integer failed, List<String> errorMessages) {
        String subject = 'Batch Process Completed';
        String body = 'Total Records Processed: ' + totalProcessed +
                      '\nSuccessful Records: ' + successful +
                      '\nFailed Records: ' + failed;

        if (!errorMessages.isEmpty()) {
            body += '\n\nError Messages:\n' + String.join(errorMessages, '\n');
        }

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new String[] { 'admin@example.com' }); // Replace with actual admin email
        email.setSubject(subject);
        email.setPlainTextBody(body);
        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { email });
    }
}

}