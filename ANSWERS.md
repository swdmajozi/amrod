# Senior Developer Technical Assessment - Solutions

## SQL Section

### 1. Pagination Query for Listing Orders

```sql
-- Offset-based pagination (good for UI with page numbers)
SELECT OrderId, OrderNumber, CustomerId, TotalAmount, Status, CreatedAt
FROM Orders
ORDER BY CreatedAt DESC, OrderId DESC
OFFSET @PageSize * (@PageNumber - 1) ROWS
FETCH NEXT @PageSize ROWS ONLY;

-- Keyset pagination (better performance for large datasets)
SELECT OrderId, OrderNumber, CustomerId, TotalAmount, Status, CreatedAt
FROM Orders
WHERE (CreatedAt, OrderId) < (@LastCreatedAt, @LastOrderId)
ORDER BY CreatedAt DESC, OrderId DESC
FETCH NEXT @PageSize ROWS ONLY;
```

**Rationale**: Keyset pagination avoids costly OFFSET operations and is ideal for infinite scroll. Offset is simpler for traditional paging UIs.

---

### 2. Top Spenders Over Last 90 Days

```sql
WITH RecentOrders AS (
    SELECT CustomerId, TotalAmount
    FROM Orders
    WHERE CreatedAt >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
    AND Status IN ('Completed', 'Shipped')
)
SELECT TOP 10
    C.CustomerId,
    C.CustomerName,
    C.Email,
    COUNT(RO.CustomerId) AS OrderCount,
    SUM(RO.TotalAmount) AS TotalSpent,
    AVG(RO.TotalAmount) AS AvgOrderValue
FROM RecentOrders RO
JOIN Customers C ON RO.CustomerId = C.CustomerId
GROUP BY C.CustomerId, C.CustomerName, C.Email
ORDER BY TotalSpent DESC;
```

**Rationale**: CTE improves readability. Date filter uses DATEADD for consistency. Filters by completed orders only.

---

### 3. Index Strategy

```sql
-- Composite index for filtering by CustomerId and Status
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_Status_CreatedAt
ON Orders(CustomerId, Status, CreatedAt DESC)
INCLUDE (OrderNumber, TotalAmount);

-- Separate index for CreatedAt range queries
CREATE NONCLUSTERED INDEX IX_Orders_CreatedAt
ON Orders(CreatedAt DESC)
INCLUDE (CustomerId, Status, TotalAmount);

-- Index for top spenders query
CREATE NONCLUSTERED INDEX IX_Orders_CreatedAt_Status_CustomerId
ON Orders(CreatedAt DESC, Status)
INCLUDE (CustomerId, TotalAmount);
```

**Rationale**:
- **Leading column**: Most selective filter (CustomerId or CreatedAt)
- **Included columns**: Avoid lookups to the clustered index
- **DESC ordering**: Matches query sorting needs
- **Composite keys**: Cover multiple filter combinations

---

### 4. Execution Plan Analysis & Removing Key Lookups

**Problem**: Key lookups occur when non-key columns must be fetched from the clustered index.

```sql
-- BEFORE: Key Lookup issue
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId
ON Orders(CustomerId);

SELECT OrderId, OrderNumber, TotalAmount  -- TotalAmount not in index
FROM Orders
WHERE CustomerId = @CustomerId;

-- AFTER: Include TotalAmount to avoid lookup
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_Optimized
ON Orders(CustomerId)
INCLUDE (OrderNumber, TotalAmount);  -- Add INCLUDE clause

SELECT OrderId, OrderNumber, TotalAmount
FROM Orders
WHERE CustomerId = @CustomerId;
```

**Analysis**:
1. Run `SET STATISTICS IO ON` to measure logical reads
2. Look for "Clustered Index Seek" with high page reads = lookup issue
3. Add missing columns to INCLUDE clause
4. Verify reduction in logical reads

---

### 5. Optimistic Concurrency Using RowVersion

```sql
-- Schema
ALTER TABLE Orders ADD RowVersion ROWVERSION;

-- Update with optimistic concurrency
UPDATE Orders
SET Status = 'Shipped', UpdatedAt = GETUTCDATE()
WHERE OrderId = @OrderId
AND RowVersion = @OriginalRowVersion;

IF @@ROWCOUNT = 0
    THROW 50001, 'Concurrency conflict: Order was modified by another user.', 1;

-- SELECT current RowVersion before update
SELECT OrderId, Status, RowVersion
FROM Orders
WHERE OrderId = @OrderId;
```

**Advantages**:
- No locks or blocking
- Detects conflicts at update time
- Lightweight compared to pessimistic locking

---

### 6. Deadlock Scenario & Mitigation

**Deadlock Scenario**:
```
Transaction A: OrderLineItems → Orders (locks in order)
Transaction B: Orders → OrderLineItems (locks in reverse order)
```

**Mitigation Strategy**:

```sql
-- ALWAYS lock tables in consistent order
-- Transaction A
BEGIN TRANSACTION;
    SELECT @OrderTotal = SUM(UnitPrice * Quantity)
    FROM OrderLineItems (UPDLOCK)  -- Lock intention
    WHERE OrderId = @OrderId;
    
    UPDATE Orders
    SET TotalAmount = @OrderTotal
    WHERE OrderId = @OrderId;
COMMIT;

-- Use SERIALIZABLE isolation with query hints
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRANSACTION;
    UPDATE Orders (HOLDLOCK)
    SET Status = 'Processing'
    WHERE OrderId = @OrderId;
    
    UPDATE OrderLineItems (HOLDLOCK)
    SET Processed = 1
    WHERE OrderId = @OrderId;
COMMIT;
```

**Best Practices**:
1. Always acquire locks in the same order across transactions
2. Minimize transaction scope
3. Use appropriate isolation levels (READ COMMITTED preferred)
4. Add retry logic with exponential backoff

---

### 7. Window Function Example - Running Totals per Customer

```sql
SELECT
    OrderId,
    CustomerId,
    OrderNumber,
    TotalAmount,
    CreatedAt,
    SUM(TotalAmount) OVER (
        PARTITION BY CustomerId
        ORDER BY CreatedAt, OrderId
    ) AS RunningTotal,
    SUM(TotalAmount) OVER (
        PARTITION BY CustomerId
        ORDER BY YEAR(CreatedAt), MONTH(CreatedAt)
    ) AS MonthlyTotal,
    ROW_NUMBER() OVER (
        PARTITION BY CustomerId
        ORDER BY CreatedAt DESC
    ) AS OrderSequence,
    LAG(TotalAmount) OVER (
        PARTITION BY CustomerId
        ORDER BY CreatedAt
    ) AS PreviousOrderAmount,
    LEAD(TotalAmount) OVER (
        PARTITION BY CustomerId
        ORDER BY CreatedAt
    ) AS NextOrderAmount
FROM Orders
WHERE CustomerId = @CustomerId
ORDER BY CreatedAt;
```

**Key Functions**:
- `SUM() OVER`: Running totals
- `ROW_NUMBER()`: Ranking without ties
- `LAG/LEAD`: Access previous/next rows
- `PARTITION BY`: Group calculations

---

### 8. Partitioning Strategy for Large Datasets

```sql
-- Create partition function by CreatedAt (quarterly)
CREATE PARTITION FUNCTION pfOrders (DATETIME2)
AS RANGE LEFT FOR VALUES
    ('2024-01-01', '2024-04-01', '2024-07-01', '2024-10-01',
     '2025-01-01', '2025-04-01', '2025-07-01', '2025-10-01');

-- Create partition scheme
CREATE PARTITION SCHEME psOrders
AS PARTITION pfOrders
TO (FileGroup1, FileGroup2, FileGroup3, FileGroup4,
    FileGroup5, FileGroup6, FileGroup7, FileGroup8, FileGroup9);

-- Create partitioned table
CREATE TABLE Orders_Partitioned (
    OrderId BIGINT PRIMARY KEY,
    OrderNumber NVARCHAR(50),
    CustomerId INT,
    TotalAmount DECIMAL(19,2),
    Status NVARCHAR(50),
    CreatedAt DATETIME2
) ON psOrders (CreatedAt);

-- Partitioned index
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_Partitioned
ON Orders_Partitioned(CustomerId)
INCLUDE (TotalAmount)
ON psOrders (CreatedAt);
```

**Benefits**:
- **Improved query performance**: Partition elimination for date ranges
- **Faster maintenance**: Index rebuilds on individual partitions
- **Data archival**: Move old partitions to cold storage
- **Parallel processing**: Queries can scan multiple partitions

---

### 9. Outbox Pattern Database Design

```sql
CREATE TABLE Outbox (
    OutboxId BIGINT PRIMARY KEY IDENTITY(1,1),
    AggregateId INT NOT NULL,
    AggregateType NVARCHAR(255) NOT NULL,
    EventType NVARCHAR(255) NOT NULL,
    EventPayload NVARCHAR(MAX) NOT NULL,  -- JSON
    CreatedAt DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
    ProcessedAt DATETIME2 NULL,
    ProcessingAttempts INT DEFAULT 0,
    LastError NVARCHAR(MAX) NULL,
    IsProcessed BIT DEFAULT 0
);

CREATE NONCLUSTERED INDEX IX_Outbox_IsProcessed_CreatedAt
ON Outbox(IsProcessed, CreatedAt)
INCLUDE (EventPayload, EventType);

-- Transactional consistency: Order and Outbox in same transaction
BEGIN TRANSACTION;
    INSERT INTO Orders (OrderNumber, CustomerId, TotalAmount, Status)
    VALUES (@OrderNumber, @CustomerId, @TotalAmount, 'Pending');
    
    DECLARE @OrderId INT = SCOPE_IDENTITY();
    
    INSERT INTO Outbox (AggregateId, AggregateType, EventType, EventPayload)
    VALUES (
        @OrderId,
        'Order',
        'OrderCreated',
        JSON_OBJECT('orderId': @OrderId, 'customerId': @CustomerId, 'totalAmount': @TotalAmount)
    );
COMMIT;

-- Polling query (read unprocessed events)
SELECT TOP 100
    OutboxId,
    AggregateId,
    EventType,
    EventPayload
FROM Outbox
WHERE IsProcessed = 0
ORDER BY CreatedAt
FOR UPDATE;
```

**Key Points**:
- Order and event stored in **same transaction**
- Polling job checks for unprocessed events
- Idempotent event handler (can retry safely)

---

### 10. Stored Procedure Example - Transaction Report

```sql
CREATE OR ALTER PROCEDURE sp_GenerateTransactionReport
    @StartDate DATETIME2,
    @EndDate DATETIME2,
    @MinimumAmount DECIMAL(19,2) = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Validate inputs
        IF @StartDate >= @EndDate
            THROW 50001, 'StartDate must be before EndDate', 1;
        
        IF @MinimumAmount < 0
            THROW 50002, 'MinimumAmount cannot be negative', 1;
        
        -- Report with transaction summary
        WITH TransactionSummary AS (
            SELECT
                C.CustomerId,
                C.CustomerName,
                COUNT(O.OrderId) AS OrderCount,
                SUM(O.TotalAmount) AS TotalAmount,
                AVG(O.TotalAmount) AS AvgOrderAmount,
                MIN(O.CreatedAt) AS FirstOrderDate,
                MAX(O.CreatedAt) AS LastOrderDate,
                SUM(CASE WHEN O.Status = 'Completed' THEN 1 ELSE 0 END) AS CompletedOrders,
                SUM(CASE WHEN O.Status = 'Cancelled' THEN 1 ELSE 0 END) AS CancelledOrders
            FROM Orders O
            INNER JOIN Customers C ON O.CustomerId = C.CustomerId
            WHERE O.CreatedAt >= @StartDate
            AND O.CreatedAt < @EndDate
            GROUP BY C.CustomerId, C.CustomerName
            HAVING SUM(O.TotalAmount) >= @MinimumAmount
        )
        SELECT
            CustomerId,
            CustomerName,
            OrderCount,
            TotalAmount,
            AvgOrderAmount,
            FirstOrderDate,
            LastOrderDate,
            CompletedOrders,
            CancelledOrders,
            CAST(CompletedOrders AS FLOAT) / NULLIF(OrderCount, 0) AS CompletionRate,
            GETUTCDATE() AS ReportGeneratedAt
        FROM TransactionSummary
        ORDER BY TotalAmount DESC;
        
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(MAX) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        THROW @ErrorNumber, @ErrorMessage, 1;
    END CATCH
END;

-- Usage
EXEC sp_GenerateTransactionReport
    @StartDate = '2024-01-01',
    @EndDate = '2024-12-31',
    @MinimumAmount = 1000;
```

**Features**:
- Input validation
- Error handling with TRY/CATCH
- CTE for complex logic
- Computed metrics (CompletionRate)
- Proper documentation

---

## Part 3 - Advanced Enhancements

*See implementation files in `/src/Advanced` directory*

### Enhancement 1: Messaging Reliability (Outbox Pattern)
- [OutboxPublisher.cs](../src/Advanced/Messaging/OutboxPublisher.cs)
- [OutboxProcessor.cs](../src/Advanced/Messaging/OutboxProcessor.cs)

### Enhancement 2: FX Conversion
- [FxConversionService.cs](../src/Advanced/FxConversion/FxConversionService.cs)
- [ExchangeRateProvider.cs](../src/Advanced/FxConversion/ExchangeRateProvider.cs)

### Enhancement 3: Observability
- [StructuredLogging.cs](../src/Advanced/Observability/StructuredLogging.cs)
- [MetricsCollector.cs](../src/Advanced/Observability/MetricsCollector.cs)

### Enhancement 4: DevOps
- [docker-compose.yml](../docker-compose.yml)
- [.github/workflows/ci.yml](../.github/workflows/ci.yml)

### Enhancement 5: GraphQL
- [OrderSchema.graphql](../src/Advanced/GraphQL/OrderSchema.graphql)
- [OrderQueryResolver.cs](../src/Advanced/GraphQL/OrderQueryResolver.cs)

### Enhancement 6: EF Core Migrations
- [InitialCreate Migration](../src/Data/Migrations/InitialCreate.cs)
- [AddOutboxPattern Migration](../src/Data/Migrations/AddOutboxPattern.cs)

---

## Summary

All SQL solutions follow **best practices**:
✅ Proper indexing strategies
✅ Query optimization
✅ Concurrency handling
✅ Error handling
✅ Performance considerations
✅ Production-ready patterns (Outbox, pagination, windowing)
