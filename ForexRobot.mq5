//+------------------------------------------------------------------+
//|                                            ForexRobot.mq5        |
//|   Simple EMA(50/200) crossover EA with RSI confirmation          |
//|   and ATR-based position sizing for MetaTrader 5                 |
//|                                                                  |
//|   DISCLAIMER:                                                    |
//|   Trading Forex involves significant risk. This code is          |
//|   for educational purposes only. Test on a demo account first.   |
//+------------------------------------------------------------------+
#property copyright   "© 2025 YourName"
#property link        "https://example.com"
#property version     "1.00"
#property strict
#property script_show_inputs

//--- input parameters
input int      FastMAPeriod      = 50;      // Fast EMA
input int      SlowMAPeriod      = 200;     // Slow EMA
input int      RSIPeriod         = 14;      // RSI period
input double   RSIBuyLevel       = 55;      // Minimum RSI to allow BUY
input double   RSISellLevel      = 45;      // Maximum RSI to allow SELL
input int      ATRPeriod         = 14;      // ATR period
input double   SL_ATR_Mult       = 1.5;     // Stop-loss  multiple of ATR
input double   TP_ATR_Mult       = 3.0;     // Take-profit multiple of ATR
input double   Risk_Percent      = 1.0;     // % of free margin to risk per trade
input uint     Slippage          = 3;       // Max slippage in points
input ulong    MagicNumber       = 20250709;// EA magic number
input bool     UseTrailingStop   = true;    // Enable trailing stop
input double   TS_ATR_Mult       = 1.0;     // Trail stop distance (ATR multiple)

//--- global handles
int            fastMAHandle;
int            slowMAHandle;
int            rsiHandle;
int            atrHandle;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   fastMAHandle=iMA(_Symbol,_Period,FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   slowMAHandle=iMA(_Symbol,_Period,SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   rsiHandle  =iRSI(_Symbol,_Period,RSIPeriod,PRICE_CLOSE);
   atrHandle  =iATR(_Symbol,_Period,ATRPeriod);
   if(fastMAHandle==INVALID_HANDLE || slowMAHandle==INVALID_HANDLE || rsiHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE)
     {
      Print("Failed to create indicator handle");
      return(INIT_FAILED);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(fastMAHandle!=INVALID_HANDLE)  IndicatorRelease(fastMAHandle);
   if(slowMAHandle!=INVALID_HANDLE)  IndicatorRelease(slowMAHandle);
   if(rsiHandle!=INVALID_HANDLE)     IndicatorRelease(rsiHandle);
   if(atrHandle!=INVALID_HANDLE)     IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime lastBarTime=0;
   // Only evaluate once per completed bar
   datetime currentBarTime=iTime(_Symbol,_Period,0);
   if(currentBarTime==lastBarTime) // same bar
      return;
   lastBarTime=currentBarTime;

   double fastMA[2],slowMA[2],rsi[2],atr[2];
   if(CopyBuffer(fastMAHandle,0,1,2,fastMA)<=0) return;
   if(CopyBuffer(slowMAHandle,0,1,2,slowMA)<=0) return;
   if(CopyBuffer(rsiHandle ,0,1,2,rsi)<=0) return;
   if(CopyBuffer(atrHandle ,0,1,2,atr)<=0) return;

   // Determine crossover
   bool bullishCross = (fastMA[1] < slowMA[1]) && (fastMA[0] > slowMA[0]);
   bool bearishCross = (fastMA[1] > slowMA[1]) && (fastMA[0] < slowMA[0]);

   // Manage existing positions (optional trailing)
   ManagePositions(atr[0]);

   // If already in trade, skip new entries
   if(PositionsTotalByMagic() > 0) return;

   // Calculate SL/TP distances in points
   double atrPoints = atr[0]/_Point;
   double slPoints  = SL_ATR_Mult * atrPoints;
   double tpPoints  = TP_ATR_Mult * atrPoints;

   // Entry conditions
   if(bullishCross && rsi[0]>=RSIBuyLevel)
      OpenPosition(ORDER_TYPE_BUY ,slPoints,tpPoints);
   else if(bearishCross && rsi[0]<=RSISellLevel)
      OpenPosition(ORDER_TYPE_SELL,slPoints,tpPoints);
  }

//+------------------------------------------------------------------+
//| Count positions by this EA                                       |
//+------------------------------------------------------------------+
int PositionsTotalByMagic()
  {
   int total=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetTicket(i))
        {
         if((ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
               total++;
        }
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Calculate correct lot size based on risk percentage              |
//+------------------------------------------------------------------+
double CalculateLots(double slPoints)
  {
   if(slPoints<=0) return(0.0);
   double risk = Risk_Percent/100.0;
   double tickValue=MarketInfo(_Symbol,MODE_TICKVALUE);
   double contractSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   double slPriceDist=slPoints*_Point;
   double moneyRisk = AccountFreeMargin()*risk;
   // Lot = moneyRisk / (SL price distance * (contractSize/PointValue))
   double lot = moneyRisk / (slPriceDist*contractSize/tickValue);
   lot = MathMax(lot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   lot = MathMin(lot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));
   lot = NormalizeDouble(lot,SymbolInfoInteger(_Symbol,SYMBOL_VOLUME_DIGITS));
   return(lot);
  }

//+------------------------------------------------------------------+
//| Open position helper                                             |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_ORDER_TYPE type,double slPoints,double tpPoints)
  {
   double price   = (type==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slPrice = (type==ORDER_TYPE_BUY)?price-slPoints*_Point:price+slPoints*_Point;
   double tpPrice = (type==ORDER_TYPE_BUY)?price+tpPoints*_Point:price-tpPoints*_Point;
   double lots    = CalculateLots(slPoints);
   if(lots<=0) return;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   req.action   =TRADE_ACTION_DEAL;
   req.symbol   =_Symbol;
   req.volume   =lots;
   req.type     =type;
   req.price    =price;
   req.sl       =slPrice;
   req.tp       =tpPrice;
   req.slippage =Slippage;
   req.magic    =MagicNumber;
   req.deviation=Slippage;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment  ="ForexRobot";
   if(!OrderSend(req,res))
      Print("OrderSend failed: ",GetLastError());
   else if(res.retcode!=10009 && res.retcode!=10008)
      Print("OrderSend retcode=",res.retcode);
  }

//+------------------------------------------------------------------+
//| Manage trailing stop / break-even                                |
//+------------------------------------------------------------------+
void ManagePositions(double atrCurrent)
  {
   if(!UseTrailingStop) return;
   double trailPoints = TS_ATR_Mult * atrCurrent / _Point;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionSelectByIndex(i))
        {
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

         ulong  ticket = PositionGetInteger(POSITION_TICKET);
         double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl       = PositionGetDouble(POSITION_SL);
         double current  = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double newSL;
         bool   shouldModify=false;
         if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
           {
            newSL = current - trailPoints*_Point;
            if(newSL>sl && newSL>priceOpen)
               shouldModify=true;
           }
         else // sell
           {
            newSL = current + trailPoints*_Point;
            if(newSL<sl && newSL<priceOpen)
               shouldModify=true;
           }
         if(shouldModify)
           {
            MqlTradeRequest req; MqlTradeResult res;
            ZeroMemory(req);
            req.action   = TRADE_ACTION_SLTP;
            req.position = ticket;
            req.symbol   = _Symbol;
            req.sl       = newSL;
            req.tp       = PositionGetDouble(POSITION_TP); // unchanged
            if(!OrderSend(req,res))
               Print("Modify SL failed: ",GetLastError());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+