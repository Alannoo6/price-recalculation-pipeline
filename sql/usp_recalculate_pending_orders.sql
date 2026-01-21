USE [DemoERP]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* 
    Stored Procedure: dbo.usp_recalculate_pending_orders_v2
    Purpose:
      - Identify pending order lines whose stored unit price differs from the current price list
      - Update unit price and recalculate dependent amounts (taxes, discounts, net values, totals)
    Notes:
      - All names and structures have been anonymized for portfolio purposes.
*/

ALTER PROCEDURE dbo.usp_recalculate_pending_orders_v2
(
      @StartDate     date,
      @Divisions     varchar(MAX),
      @OrderTypes    varchar(MAX),
      @ProductType   varchar(10) = NULL,
      @PriceLists    varchar(MAX),
      @OrderNumber   varchar(30) = NULL,
      @ProductCode   varchar(50) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        /* STEP 0: Define target lines
           Pending lines where:
             - ordered qty > invoiced qty
             - ordered qty > delivered qty
             - stored unit price differs from current price list price
        */
        IF OBJECT_ID('tempdb..#TargetLines') IS NOT NULL DROP TABLE #TargetLines;
        IF OBJECT_ID('tempdb..#AffectedOrders') IS NOT NULL DROP TABLE #AffectedOrders;

        SELECT
            ol.division_id,
            ol.order_type,
            ol.order_number,
            ol.line_number,
            ol.product_id
        INTO #TargetLines
        FROM sales.order_lines ol
        INNER JOIN sales.order_headers oh
            ON oh.division_id   = ol.division_id
           AND oh.order_type    = ol.order_type
           AND oh.order_number  = ol.order_number
        INNER JOIN master.products pr
            ON pr.product_id = ol.product_id
        INNER JOIN master.price_list_items pli
            ON pli.product_id    = ol.product_id
           AND pli.price_list_id IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PriceLists, ','))
        WHERE oh.issue_date > @StartDate
          AND ol.division_id IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Divisions, ','))
          AND ol.order_type  IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@OrderTypes, ','))
          AND ol.qty_invoiced  < ol.qty_ordered
          AND ol.qty_delivered < ol.qty_ordered
          AND ISNULL(ol.unit_price_excl_tax, -1) <> ISNULL(pli.unit_price, -1)
          AND (@OrderNumber IS NULL OR ol.order_number = @OrderNumber)
          AND (@ProductCode IS NULL OR ol.product_id = @ProductCode)
          AND (@ProductType IS NULL OR pr.product_type = @ProductType);

        -- Affected orders list
        SELECT DISTINCT
            division_id,
            order_type,
            order_number
        INTO #AffectedOrders
        FROM #TargetLines;

        IF NOT EXISTS (SELECT 1 FROM #TargetLines)
        BEGIN
            COMMIT TRAN;
            SELECT 'No pending lines to recalculate.' AS Message;
            RETURN;
        END

        /* STEP 1: Update unit price from price list
           IMPORTANT:
             - In the original script, a specific price list was hardcoded.
             - For portfolio/generalization, we update using the same @PriceLists filter.
             - If multiple price lists match a product, this approach must be clarified
               (e.g., pick the order’s assigned price list or define precedence).
        */
        UPDATE ol
           SET ol.unit_price_excl_tax = pli.unit_price
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number
        INNER JOIN master.price_list_items pli
            ON pli.product_id = ol.product_id
           AND pli.price_list_id IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PriceLists, ','))
        WHERE ISNULL(ol.unit_price_excl_tax, -1) <> ISNULL(pli.unit_price, -1)
           OR ol.unit_price_excl_tax IS NULL;

        DECLARE @Step1 INT = @@ROWCOUNT;

        /* STEP 2: Recalculate line-level pre-tax amount of taxes:
           line_tax_amount = unit_price_excl_tax * (sum(order_tax_rate)/100)
        */
        ;WITH OrderTaxRate AS (
            SELECT
                ot.division_id,
                ot.order_type,
                ot.order_number,
                SUM(ot.tax_rate) AS total_tax_rate
            FROM sales.order_taxes ot
            INNER JOIN #AffectedOrders a
                ON a.division_id  = ot.division_id
               AND a.order_type   = ot.order_type
               AND a.order_number = ot.order_number
            GROUP BY
                ot.division_id,
                ot.order_type,
                ot.order_number
        )
        UPDATE ol
           SET ol.unit_tax_amount = ROUND(ISNULL(ol.unit_price_excl_tax,0) * (ISNULL(r.total_tax_rate,0) / 100.0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number
        INNER JOIN OrderTaxRate r
            ON r.division_id   = ol.division_id
           AND r.order_type    = ol.order_type
           AND r.order_number  = ol.order_number;

        DECLARE @Step2 INT = @@ROWCOUNT;

        /* STEP 3: unit_price_incl_tax = unit_price_excl_tax + unit_tax_amount */
        UPDATE ol
           SET ol.unit_price_incl_tax = ROUND(ISNULL(ol.unit_price_excl_tax,0) + ISNULL(ol.unit_tax_amount,0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step3 INT = @@ROWCOUNT;

        /* STEP 4: gross_subtotal_excl_tax = unit_price_excl_tax * qty_ordered */
        UPDATE ol
           SET ol.gross_subtotal_excl_tax = ROUND(ISNULL(ol.unit_price_excl_tax,0) * ISNULL(ol.qty_ordered,0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step4 INT = @@ROWCOUNT;

        /* STEP 5: gross_subtotal_incl_tax = unit_price_incl_tax * qty_ordered */
        UPDATE ol
           SET ol.gross_subtotal_incl_tax = ROUND(ISNULL(ol.unit_price_incl_tax,0) * ISNULL(ol.qty_ordered,0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step5 INT = @@ROWCOUNT;

        /* STEP 6-7: Line discounts (excl/incl tax)
           discount_amount = gross_subtotal * (sum(line_discount_pct)/100)
        */
        ;WITH LineDiscountPct AS (
            SELECT
                ld.division_id,
                ld.order_type,
                ld.order_number,
                ld.line_number,
                SUM(ld.discount_pct) AS total_discount_pct
            FROM sales.order_line_discounts ld
            INNER JOIN #AffectedOrders a
                ON a.division_id  = ld.division_id
               AND a.order_type   = ld.order_type
               AND a.order_number = ld.order_number
            GROUP BY
                ld.division_id,
                ld.order_type,
                ld.order_number,
                ld.line_number
        )
        UPDATE ol
           SET ol.line_discount_excl_tax = ROUND(ISNULL(ol.gross_subtotal_excl_tax,0) * (ISNULL(p.total_discount_pct,0)/100.0), 2),
               ol.line_discount_incl_tax = ROUND(ISNULL(ol.gross_subtotal_incl_tax,0) * (ISNULL(p.total_discount_pct,0)/100.0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number
        LEFT JOIN LineDiscountPct p
            ON p.division_id   = ol.division_id
           AND p.order_type    = ol.order_type
           AND p.order_number  = ol.order_number
           AND p.line_number   = ol.line_number;

        DECLARE @Step6 INT = @@ROWCOUNT; -- includes excl
        DECLARE @Step7 INT = @Step6;     -- includes incl

        /* STEP 8: net_subtotal_excl_tax = gross_subtotal_excl_tax - line_discount_excl_tax */
        UPDATE ol
           SET ol.net_subtotal_excl_tax = ROUND(ISNULL(ol.gross_subtotal_excl_tax,0) - ISNULL(ol.line_discount_excl_tax,0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step8 INT = @@ROWCOUNT;

        /* STEP 9: net_subtotal_incl_tax = gross_subtotal_incl_tax - line_discount_incl_tax */
        UPDATE ol
           SET ol.net_subtotal_incl_tax = ROUND(ISNULL(ol.gross_subtotal_incl_tax,0) - ISNULL(ol.line_discount_incl_tax,0), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step9 INT = @@ROWCOUNT;

        /* STEP 10: net_unit_price_excl_tax = unit_price_excl_tax - (line_discount_excl_tax / qty_ordered) */
        UPDATE ol
           SET ol.net_unit_price_excl_tax =
               ROUND(ISNULL(ol.unit_price_excl_tax,0) - (ISNULL(ol.line_discount_excl_tax,0) / NULLIF(ol.qty_ordered,0)), 2)
        FROM sales.order_lines ol
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step10 INT = @@ROWCOUNT;

        /* STEP 11: Recalculate header totals from line net subtotals */
        ;WITH OrderTotals AS (
            SELECT
                ol.division_id,
                ol.order_type,
                ol.order_number,
                SUM(ISNULL(ol.net_subtotal_excl_tax,0)) AS total_excl_tax,
                SUM(ISNULL(ol.net_subtotal_incl_tax,0)) AS total_incl_tax
            FROM sales.order_lines ol
            INNER JOIN #AffectedOrders a
                ON a.division_id  = ol.division_id
               AND a.order_type   = ol.order_type
               AND a.order_number = ol.order_number
            GROUP BY
                ol.division_id,
                ol.order_type,
                ol.order_number
        )
        UPDATE oh
           SET oh.total_excl_tax = t.total_excl_tax,
               oh.total_incl_tax = t.total_incl_tax
        FROM sales.order_headers oh
        INNER JOIN OrderTotals t
            ON t.division_id  = oh.division_id
           AND t.order_type   = oh.order_type
           AND t.order_number = oh.order_number;

        DECLARE @Step11 INT = @@ROWCOUNT;

        /* STEP 12: Sync line discount breakdown table with recalculated line discounts */
        UPDATE ld
           SET ld.discount_amount_excl_tax = ol.line_discount_excl_tax,
               ld.discount_amount_incl_tax = ol.line_discount_incl_tax
        FROM sales.order_line_discounts ld
        INNER JOIN sales.order_lines ol
            ON ol.division_id   = ld.division_id
           AND ol.order_type    = ld.order_type
           AND ol.order_number  = ld.order_number
           AND ol.line_number   = ld.line_number
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step12 INT = @@ROWCOUNT;

        /* STEP 13: Header-level discounts (if any) based on order base (sum of net subtotals) */
        ;WITH OrderBase AS (
            SELECT
                ol.division_id,
                ol.order_type,
                ol.order_number,
                SUM(ISNULL(ol.net_subtotal_excl_tax,0)) AS base_excl_tax,
                SUM(ISNULL(ol.net_subtotal_incl_tax,0)) AS base_incl_tax
            FROM sales.order_lines ol
            INNER JOIN #AffectedOrders a
                ON a.division_id  = ol.division_id
               AND a.order_type   = ol.order_type
               AND a.order_number = ol.order_number
            GROUP BY
                ol.division_id,
                ol.order_type,
                ol.order_number
        ),
        HeaderDiscountPct AS (
            SELECT
                hd.division_id,
                hd.order_type,
                hd.order_number,
                SUM(hd.discount_pct) AS total_discount_pct
            FROM sales.order_header_discounts hd
            INNER JOIN #AffectedOrders a
                ON a.division_id  = hd.division_id
               AND a.order_type   = hd.order_type
               AND a.order_number = hd.order_number
            WHERE hd.discount_pct > 0
            GROUP BY
                hd.division_id,
                hd.order_type,
                hd.order_number
        )
        UPDATE hd
           SET hd.discount_amount_excl_tax = ROUND(b.base_excl_tax * (p.total_discount_pct/100.0), 2),
               hd.discount_amount_incl_tax = ROUND(b.base_incl_tax * (p.total_discount_pct/100.0), 2)
        FROM sales.order_header_discounts hd
        INNER JOIN HeaderDiscountPct p
            ON p.division_id  = hd.division_id
           AND p.order_type   = hd.order_type
           AND p.order_number = hd.order_number
        INNER JOIN OrderBase b
            ON b.division_id  = hd.division_id
           AND b.order_type   = hd.order_type
           AND b.order_number = hd.order_number
        WHERE hd.discount_pct > 0;

        DECLARE @Step13 INT = @@ROWCOUNT;

        /* STEP 14: Update line-level tax base table */
        UPDATE lt
           SET lt.taxable_amount = ol.net_subtotal_excl_tax
        FROM sales.order_line_taxes lt
        INNER JOIN sales.order_lines ol
            ON ol.division_id   = lt.division_id
           AND ol.order_type    = lt.order_type
           AND ol.order_number  = lt.order_number
           AND ol.line_number   = lt.line_number
        INNER JOIN #TargetLines t
            ON t.division_id   = ol.division_id
           AND t.order_type    = ol.order_type
           AND t.order_number  = ol.order_number
           AND t.line_number   = ol.line_number;

        DECLARE @Step14 INT = @@ROWCOUNT;

        /* STEP 15: Recalculate line-level tax amounts */
        UPDATE lt
           SET lt.tax_amount = ROUND(ISNULL(lt.taxable_amount,0) * (ISNULL(lt.tax_rate,0)/100.0), 2)
        FROM sales.order_line_taxes lt
        INNER JOIN #AffectedOrders a
            ON a.division_id  = lt.division_id
           AND a.order_type   = lt.order_type
           AND a.order_number = lt.order_number;

        DECLARE @Step15 INT = @@ROWCOUNT;

        /* STEP 16: Update header-level tax base from header total_excl_tax */
        UPDATE ot
           SET ot.taxable_amount = oh.total_excl_tax
        FROM sales.order_taxes ot
        INNER JOIN #AffectedOrders a
            ON a.division_id  = ot.division_id
           AND a.order_type   = ot.order_type
           AND a.order_number = ot.order_number
        INNER JOIN sales.order_headers oh
            ON oh.division_id  = ot.division_id
           AND oh.order_type   = ot.order_type
           AND oh.order_number = ot.order_number;

        DECLARE @Step16 INT = @@ROWCOUNT;

        /* STEP 17: Recalculate header-level tax totals */
        UPDATE ot
           SET ot.tax_amount = ROUND(ISNULL(ot.taxable_amount,0) * (ISNULL(ot.tax_rate,0)/100.0), 2)
        FROM sales.order_taxes ot
        INNER JOIN #AffectedOrders a
            ON a.division_id  = ot.division_id
           AND a.order_type   = ot.order_type
           AND a.order_number = ot.order_number;

        DECLARE @Step17 INT = @@ROWCOUNT;

        COMMIT TRAN;

        -- Final summary
        SELECT
              (SELECT COUNT(*) FROM #TargetLines)    AS TargetLines
            , (SELECT COUNT(*) FROM #AffectedOrders) AS AffectedOrders
            , @Step1  AS Step1_UnitPriceUpdated
            , @Step2  AS Step2_UnitTaxRecalc
            , @Step3  AS Step3_UnitPriceInclTax
            , @Step4  AS Step4_GrossSubtotalExcl
            , @Step5  AS Step5_GrossSubtotalIncl
            , @Step6  AS Step6_7_LineDiscounts
            , @Step8  AS Step8_NetSubtotalExcl
            , @Step9  AS Step9_NetSubtotalIncl
            , @Step10 AS Step10_NetUnitPriceExcl
            , @Step11 AS Step11_HeaderTotals
            , @Step12 AS Step12_DiscountSync
            , @Step13 AS Step13_HeaderDiscounts
            , @Step14 AS Step14_LineTaxBase
            , @Step15 AS Step15_LineTaxAmount
            , @Step16 AS Step16_HeaderTaxBase
            , @Step17 AS Step17_HeaderTaxAmount;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        THROW;
    END CATCH
END
GO
