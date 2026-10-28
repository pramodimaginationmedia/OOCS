/** Enables eligible original order items after Order Summary creation. */
public without sharing class OrderSummaryOocsHandler {

    private static final Set<String> GROUP_BLOCKING_PRODUCT_TYPES = new Set<String>{
        'Shipping', 'Protection Plan', 'WPP 5YR', 'JPPCOMBO', 'LPPCOMBO',
        'WPP', 'JPP', 'LPP', 'FEE', 'GIFT CERT', 'Size', 'Engraving',
        'Gift Certificate', 'IN STORE', 'GROUP'
    };

    /**
    * Processes summaries in system context so sibling counts include all summary items.
    * @param orderSummaryIds Order Summary IDs to process.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static void handle(Set<Id> orderSummaryIds) {
        if (orderSummaryIds == null || orderSummaryIds.isEmpty()) {
            return;
        }

        Savepoint sp;
        String step = 'querying Order Item Summaries';
        try {
            List<OrderItemSummary> items = [
                SELECT OrderSummaryId, OriginalOrderItemId, o_web_flag__c, Type, groupingUUID__c,
                    Product_Type__c, OOCS_Enabled__c
                FROM OrderItemSummary
                WHERE OrderSummaryId IN :orderSummaryIds
            ];
            step = 'calculating OOCS eligibility';
            List<OrderItem> updates = buildUpdates(items);
            List<OrderSummary> summaryUpdates = buildSummaryUpdates(items, updates);
            if (updates.isEmpty() && summaryUpdates.isEmpty()) {
                return;
            }
            step = 'creating the OOCS update savepoint';
            sp = Database.setSavepoint();
            if (!updates.isEmpty()) {
                step = 'updating original Order Items';
                update updates;
            }
            if (!summaryUpdates.isEmpty()) {
                step = 'updating Order Summaries';
                update summaryUpdates;
            }
        } catch (Exception ex) {
            if (sp != null) {
                Database.rollback(sp);
            }
            List<Integration_API_Log__c> logs = new List<Integration_API_Log__c>();
            for (Id orderSummaryId : orderSummaryIds) {
                if (orderSummaryId != null) {
                    logs.add(IntegrationApiLogService.buildExceptionLog(ex, 'OOCS', orderSummaryId,
                        'OrderSummaryOocsHandler.handle failed while ' + step
                        + '. The bulk operation did not complete; handler updates were not retained.'));
                }
            }
            IntegrationApiLogService.insertLogs(logs);
        }
    }

    private static Map<Id, Map<String, Integer>> countGroups(List<OrderItemSummary> items) {
        Map<Id, Map<String, Integer>> groupCountsBySummary = new Map<Id, Map<String, Integer>>();
        for (OrderItemSummary item : items) {
            if (item.groupingUUID__c == null || !GROUP_BLOCKING_PRODUCT_TYPES.contains(item.Product_Type__c)) {
                continue;
            }
            if (!groupCountsBySummary.containsKey(item.OrderSummaryId)) {
                groupCountsBySummary.put(item.OrderSummaryId, new Map<String, Integer>());
            }
            Map<String, Integer> groupCounts = groupCountsBySummary.get(item.OrderSummaryId);
            Integer count = groupCounts.get(item.groupingUUID__c);
            groupCounts.put(item.groupingUUID__c, count == null ? 1 : count + 1);
        }
        return groupCountsBySummary;
    }

    @TestVisible
    private static List<OrderItem> buildUpdates(List<OrderItemSummary> items) {
        Map<Id, Map<String, Integer>> groupCountsBySummary = countGroups(items);
        Map<Id, OrderItem> updatesById = new Map<Id, OrderItem>();
        for (OrderItemSummary item : items) {
            if (item.o_web_flag__c != 'R' || item.Type != 'Order Product' || item.OriginalOrderItemId == null
                || GROUP_BLOCKING_PRODUCT_TYPES.contains(item.Product_Type__c)) {
                continue;
            }
            Map<String, Integer> groupCounts = groupCountsBySummary.get(item.OrderSummaryId);
            Integer groupCount = groupCounts == null ? null : groupCounts.get(item.groupingUUID__c);
            if (item.groupingUUID__c == null || groupCount == null || groupCount == 0) {
                updatesById.put(item.OriginalOrderItemId, new OrderItem(
                    Id = item.OriginalOrderItemId,
                    OOCS_Enabled__c = true
                ));
            }
        }
        return updatesById.values();
    }

    @TestVisible
    private static List<OrderSummary> buildSummaryUpdates(List<OrderItemSummary> items, List<OrderItem> itemUpdates) {
        Set<Id> enabledItemIds = new Map<Id, OrderItem>(itemUpdates).keySet();
        Map<Id, OrderSummary> summariesById = new Map<Id, OrderSummary>();
        for (OrderItemSummary item : items) {
            if (!summariesById.containsKey(item.OrderSummaryId)) {
                summariesById.put(item.OrderSummaryId, new OrderSummary(
                    Id = item.OrderSummaryId,
                    OOCS_Enabled__c = false
                ));
            }
        }
        Set<Id> summariesWithProducts = new Set<Id>();
        for (OrderItemSummary item : items) {
            if (item.Type != 'Order Product') {
                continue;
            }
            OrderSummary summaryUpdate = summariesById.get(item.OrderSummaryId);
            if (summariesWithProducts.add(item.OrderSummaryId)) {
                summaryUpdate.OOCS_Enabled__c = true;
            }
            if (!enabledItemIds.contains(item.OriginalOrderItemId)
                && item.OOCS_Enabled__c != true) {
                summaryUpdate.OOCS_Enabled__c = false;
            }
        }
        return summariesById.values();
    }
}
