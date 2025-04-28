//+------------------------------------------------------------------+
//|  Dual Pending Orders OCO EA for MT5                              |
//|  This EA places a Buy Stop and a Sell Stop at a fixed distance   |
//|  from current price. When one triggers, the other is canceled.   |
//|  After Take Profit is hit on the open position, new pending      |
//|  orders are placed. No stop loss or time filter is used.         |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

//*** Input parameters ***//
input double   GapPoints       = 400.0;    // Gap from current price for stop orders (in points)
input double   TakeProfitPoints= 400.0;     // Take Profit in points (e.g. 10 points = 1 pip)
input double   Lots            = 4;     // Trade volume (lots)
input bool     EnableTrailing  = true;     // Enable/disable the trailing stop system
input double   BreakEvenPoints = 50.0;     // Profit points to reach before moving SL to break even
input double   TrailStepTrigger= 50.0;     // Profit increment (points) to trigger each SL move
input double   TrailStepSize   = 50.0;     // Points to move SL forward on each trigger
input int      MagicNumber     = 12345;    // Magic number to identify this EA's orders/positions

CTrade trade;  // Trading object for order operations

int OnInit()
{
   // Set the expert magic number for the trade object (so all orders use this magic)
   trade.SetExpertMagicNumber(MagicNumber);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // Get current market Bid and Ask prices
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid == 0.0 || ask == 0.0)  // safety check in case prices are not available
       return;

   // Flags to track if an EA-related position is open
   bool positionOpen = false;

   // Check all open positions for this symbol and magic number
   for(int posIndex = PositionsTotal() - 1; posIndex >= 0; --posIndex)
   {
       if(PositionGetTicket(posIndex) == 0)  // selects position by index
           continue;
       // Now the position at posIndex is selected, we can get its properties
       string posSymbol = PositionGetString(POSITION_SYMBOL);
       ulong  posMagic  = (ulong)PositionGetInteger(POSITION_MAGIC);
       if(posSymbol == _Symbol && posMagic == MagicNumber)
       {
           positionOpen = true;
           break;  // found an open position belonging to this EA on the current symbol
       }
   }

   // If a position is currently open, implement OCO logic: cancel any remaining pending order
   if(positionOpen)
   {
       // Loop through all pending orders and delete those that belong to this EA (MagicNumber)
       for(int ordIndex = OrdersTotal() - 1; ordIndex >= 0; --ordIndex)
       {
           ulong ticket = OrderGetTicket(ordIndex);
           if(ticket == 0)  // no order at this index (should not happen unless invalid index)
               continue;
           string ordSymbol = OrderGetString(ORDER_SYMBOL);
           ulong  ordMagic  = (ulong)OrderGetInteger(ORDER_MAGIC);
           // Check if this order is our EA's pending order on the current symbol
           if(ordSymbol == _Symbol && ordMagic == MagicNumber)
           {
               // It's a pending order from this EA – delete it because the opposite order has triggered
               trade.OrderDelete(ticket);
           }
       }
       return;  // exit OnTick here; wait for the open position to close (TP hit) before placing new orders
   }

   // If no position is open, ensure exactly two pending orders exist for our EA
   int eaPendingCount = 0;
   // Count current pending orders belonging to this EA on the symbol
   for(int ordIndex = OrdersTotal() - 1; ordIndex >= 0; --ordIndex)
   {
       ulong ticket = OrderGetTicket(ordIndex);
       if(ticket == 0)
           continue;
       string ordSymbol = OrderGetString(ORDER_SYMBOL);
       ulong  ordMagic  = (ulong)OrderGetInteger(ORDER_MAGIC);
       // Only count pending orders for this symbol & magic
       if(ordSymbol == _Symbol && ordMagic == MagicNumber)
           eaPendingCount++;
   }

   // If there are not exactly two pending orders, reset and place new Buy Stop and Sell Stop orders
   if(eaPendingCount != 2)
   {
       // Cancel any existing EA pending orders (to avoid duplicates or stale orders)
       if(eaPendingCount > 0)
       {
           for(int ordIndex = OrdersTotal() - 1; ordIndex >= 0; --ordIndex)
           {
               ulong ticket = OrderGetTicket(ordIndex);
               if(ticket == 0) continue;
               string ordSymbol = OrderGetString(ORDER_SYMBOL);
               ulong  ordMagic  = (ulong)OrderGetInteger(ORDER_MAGIC);
               if(ordSymbol == _Symbol && ordMagic == MagicNumber)
               {
                   trade.OrderDelete(ticket);  // remove the pending order
               }
           }
       }

       // Calculate the prices for the new pending orders
       double point    = _Point;  // point size (price tick size) for the symbol
       int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
       // Price for Buy Stop (above current Ask)
       double buyStopPrice  = NormalizeDouble(ask + GapPoints * point, digits);
       // Price for Sell Stop (below current Bid)
       double sellStopPrice = NormalizeDouble(bid - GapPoints * point, digits);

       // Ensure the pending order prices are valid (in case GapPoints is very small or zero)
       // Pending Buy must be above Ask, and pending Sell must be below Bid
       if(buyStopPrice <= ask)
           buyStopPrice = NormalizeDouble(ask + 1 * point, digits);  // at least 1 point above ask
       if(sellStopPrice >= bid)
           sellStopPrice = NormalizeDouble(bid - 1 * point, digits); // at least 1 point below bid

       // Calculate Take Profit targets for each order
       double buyTP  = NormalizeDouble(buyStopPrice + TakeProfitPoints * point, digits);
       double sellTP = NormalizeDouble(sellStopPrice - TakeProfitPoints * point, digits);
       // (No Stop Loss is set as per requirements)

       // Set a small deviation (slippage) for order placement (optional)
       trade.SetDeviationInPoints(5);

       // Place the Buy Stop pending order
       bool buyPlaced = trade.BuyStop(LotSize, buyStopPrice, _Symbol, 0.0, buyTP, ORDER_TIME_GTC, 0, "BuyStop_OCO");
       if(!buyPlaced)
       {
           Print("Error placing Buy Stop: ", GetLastError());
       }

       // Place the Sell Stop pending order
       bool sellPlaced = trade.SellStop(LotSize, sellStopPrice, _Symbol, 0.0, sellTP, ORDER_TIME_GTC, 0, "SellStop_OCO");
       if(!sellPlaced)
       {
           Print("Error placing Sell Stop: ", GetLastError());
       }
       // After placing, the EA will wait for one of these orders to trigger.
   }

   // If exactly 2 pending orders already exist, do nothing (orders are in place and waiting).
}

//+------------------------------------------------------------------+
//| Optional: Cleanup on deinitialization (EA removal)               |
//| This will delete any remaining pending orders placed by this EA. |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // When the EA is removed or chart closed, delete any pending orders left by the EA
   for(int ordIndex = OrdersTotal() - 1; ordIndex >= 0; --ordIndex)
   {
       ulong ticket = OrderGetTicket(ordIndex);
       if(ticket == 0) continue;
       string ordSymbol = OrderGetString(ORDER_SYMBOL);
       ulong  ordMagic  = (ulong)OrderGetInteger(ORDER_MAGIC);
       // Delete only this EA's pending orders on the current symbol
       if(ordSymbol == _Symbol && ordMagic == MagicNumber)
       {
           trade.OrderDelete(ticket);
       }
   }
}
