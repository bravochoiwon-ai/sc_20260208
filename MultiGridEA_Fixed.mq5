//+------------------------------------------------------------------+
//| Multi position entry + Custom trailing stop EA (20 legs)         |
//|  - 3 Grid modes                                                  |
//|    1) Manual lots + manual spacing (manual buttons removed)      |
//|    2) Auto Grid: AutoLot + spacing mode (FIXED/SPREAD/ATR)       |
//|    3) Bottom Grid: AutoLot + BottomGridPrice / lookback          |
//|  - Buttons (EN)                                                  |
//|    [Auto Grid Buy] [Auto Grid Sell]                              |
//|    [Bottom Grid Buy] [Bottom Grid Sell]                          |
//|    [Market Buy] [Market Sell]                                    |
//|    [Half Close (Each)] [Half Close (Total)]                      |
//|    [Entry] [Trailing ON/OFF]                                     |
//|    [Switch (Close&Reverse)] [Close All]                          |
//|  - Risk Cap (Account %): blocks entries + forces emergency close |
//|  - Server TP (TP0): GridRange * 0.70 (tighten only by ATR(H1))   |
//|  - TP1: Pre-hit close 50% (advantage first)                      |
//|  - After TP1: remove ALL TP on remaining positions               |
//|  - After TP1: optional auto-arm Hybrid Trailing                  |
//|  - Hybrid Trailing: Dynamic TF (1 level above chart TF)          |
//|    Update on new bar: M1->M5, M5->M15, M15->M30, M30->H1, etc   |
//|    SL = tighter of {ATR trail, prev bar 50% midpoint}            |
//|  - FIX: 모바일 주문 감지 후 리밋 주문 안정성 개선                    |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//─────────────────────────────────────────────────────────────
// Dummy section titles (input grouping)
//─────────────────────────────────────────────────────────────
input string Section_Common   = "* Common";
input string Section_Manual   = "* Manual (lots + spacing) (manual buttons removed)";
input string Section_Auto     = "* Auto Grid (AutoLot + spacing mode)";
input string Section_Bottom   = "* Bottom Grid (AutoLot + bottom range)";
input string Section_Risk     = "* Risk Cap (Account %)";
input string Section_RiskPL   = "* Risk (P/L amount exit)";
input string Section_TP       = "* Server TP / TP1 / Hybrid Trailing";
input string Section_Trailing = "* Trailing / Market / Misc";

//─────────────────────────────────────────────────────────────
// [Common]
//─────────────────────────────────────────────────────────────
input ENUM_ORDER_TYPE EntryOrderType = ORDER_TYPE_BUY; // for Entry button
input double          entry_price    = 0.0;            // limit entry price (>0 required)
input double          BottomGridPrice= 0.0;            // bottom/ceiling price (0 = auto by lookback)

// Magic numbers
input long            MagicGrid      = 10001;
input long            MagicMarket    = 10002;

//─────────────────────────────────────────────────────────────
// [Manual] spacing
// spacing unit: "PRICE" | "POINTS" | "TICKS" | "PIPS"
input string spacing_unit  = "PRICE";
input double spacing_value = 5.0;

// Auto legs 2..20
enum ENUM_AutoLegsMode
{
   AL_2 = 0, AL_3, AL_4, AL_5, AL_6, AL_7, AL_8, AL_9, AL_10,
   AL_11, AL_12, AL_13, AL_14, AL_15, AL_16, AL_17, AL_18, AL_19, AL_20
};
input ENUM_AutoLegsMode AutoLegsMode = AL_3;

// Manual lots (max 20)
// NOTE: In AutoLot FirstLot mode, EA will use symbol-specific base lot from input parameters
// (BaseLot_Gold, BaseLot_Silver, BaseLot_Bitcoin, BaseLot_Others)
// These manual lot inputs are kept for compatibility with manual lot mode.
input double lot1  = 0.30;
input double lot2  = 0.00;
input double lot3  = 0.00;
input double lot4  = 0.00;
input double lot5  = 0.00;
input double lot6  = 0.00;
input double lot7  = 0.00;
input double lot8  = 0.00;
input double lot9  = 0.00;
input double lot10 = 0.00;
input double lot11 = 0.00;
input double lot12 = 0.00;
input double lot13 = 0.00;
input double lot14 = 0.00;
input double lot15 = 0.00;
input double lot16 = 0.00;
input double lot17 = 0.00;
input double lot18 = 0.00;
input double lot19 = 0.00;
input double lot20 = 0.00;

//─────────────────────────────────────────────────────────────
// [Auto Grid] AutoLot / Spacing mode
// requested: ratio = 1.25
input double AutoLotRatio    = 1.25;

// First-lot based (default ON)
input bool   UseFirstLotMode = true;

// Symbol-specific base lots (for FirstLot mode)
input double BaseLot_Gold    = 0.02;  // XAU (Gold) base lot
input double BaseLot_Silver  = 0.02;  // XAG (Silver) base lot
input double BaseLot_Bitcoin = 0.02;  // BTC (Bitcoin) base lot
input double BaseLot_Others  = 0.30;  // Other symbols base lot

// Total lots mode (used only if UseFirstLotMode=false)
input double AutoTotalLots   = 1.0;

// Stop multiplier
enum ENUM_StopMultMode { SM_0_25=0, SM_0_5=1, SM_1_0=2, SM_1_5=3, SM_CUSTOM=4 };
input ENUM_StopMultMode StopMultMode   = SM_0_5;
input double            StopMultCustom = 0.5;

// Spacing mode (Auto Grid / Bottom Grid)
enum ENUM_SpacingMode { SP_FIXED=0, SP_SPREAD=1, SP_ATR=2 };
input ENUM_SpacingMode SpacingMode = SP_FIXED;
input double           SpreadMult  = 1.0;
input int              AtrPeriod   = 14;
input double           AtrMult     = 1.0;

//─────────────────────────────────────────────────────────────
// [Bottom Grid]
//─────────────────────────────────────────────────────────────
input int BottomLookback = 20;

// Entry button defaults
input bool UseAutoLot_Default     = false;
input bool UseBottomGridPrice_Def = false;

//─────────────────────────────────────────────────────────────
// [Risk Cap] (Account %)
//  - blocks new batch if planned worst-loss at SL exceeds cap
//  - emergency closes if current worst-loss at SL exceeds cap
//─────────────────────────────────────────────────────────────
input bool   UseRiskCapPercent = true;
input double RiskCapPercent    = 7.0;  // 2%~10% recommended (hard cap)

//─────────────────────────────────────────────────────────────
// [Risk] P/L amount exits
//─────────────────────────────────────────────────────────────
input bool   UseLossCut         = false;
input double MaxLossAmount      = 200.0;
input bool   UseProfitTake      = false;
input double TargetProfitAmount = 200.0;

//─────────────────────────────────────────────────────────────
// [Server TP / TP1 / Hybrid Trailing]
//─────────────────────────────────────────────────────────────
// Server TP (TP0): GridRange*(0.70), tightens only when ATR(H1) expands
input bool   UseServerTP           = true;
input double TP_PartialPercent     = 50.0;   // TP0 applies to advantageous volume (typically 50%)
input double TP_Ratio_Init         = 0.70;   // requested: 70%
input int    ATR_H1_Period         = 14;
input double ATR_Expand_Ratio      = 1.40;   // trigger when ATR_now > ATR_entry * ratio
input double ATR_TP_Mult           = 2.00;   // ATR-based TP distance = ATR_now * mult
input double TP_MinUpdateTickGap   = 2.0;    // avoid too-frequent tiny updates (ticks)

// TP1: pre-hit close
input bool   UseTP1_PreClose       = true;
input double TP1_ClosePercent      = 50.0;   // requested: 50% partial close
input double TP1_Buffer_ATR_Mult   = 0.10;   // TP1 buffer = max(ATR(H1)*mult, ticks*min)
input double TP1_Buffer_MinTicks   = 5.0;    // minimum buffer ticks
input bool   ShowTP1Line           = true;

// After TP1: remove ALL TP on remaining positions
input bool   RemoveAllTP_AfterTP1  = true;

// After TP1: auto arm hybrid trailing (optional)
input bool   AutoArmHybridTrailing_AfterTP1 = true;

// Hybrid Trailing (Dynamic TF: one level above chart TF)
input double Hybrid_ATR_Mult       = 1.00;   // SL_ATR distance = ATR * mult
input bool   Hybrid_UsePrevMid     = true;   // include prev bar 50% retrace midpoint

//─────────────────────────────────────────────────────────────
// [Trailing]
//─────────────────────────────────────────────────────────────
input int    TrailUpdateInterval = 1; // timer interval seconds (H1 gate inside)

//─────────────────────────────────────────────────────────────
// State / UI
//─────────────────────────────────────────────────────────────
bool     is_ordering     = false;
bool     trailingEnabled = false;

bool   g_has_target_sl   = false;
bool   g_batch_is_buy    = true;
double g_target_sl_price = 0.0;

// ★ Mobile/external lot tracking (FIXED)
double g_mobile_base_lot = 0.0;       // Mobile lot detected from external position
ulong  g_mobile_ticket   = 0;         // Track mobile position ticket
bool   g_mobile_grid_built = false;   // Flag: grid already built for mobile position
int    g_mobile_check_cooldown = 0;   // ★ Cooldown counter to prevent rapid re-checks

// For server TP management (TP0)
bool   g_has_tp           = false;
double g_tp_price         = 0.0;
double g_tp_dist_init     = 0.0;   // initial gridrange-based distance
double g_tp_dist_current  = 0.0;   // current effective distance (may tighten by ATR)
double g_atr_entry_h1     = 0.0;   // ATR snapshot at batch start
double g_grid_step_used   = 0.0;   // step used for last batch (for info only)
int    g_grid_last_index  = 0;     // last index used for last batch (for info only)

// TP1 state
bool   g_tp1_done         = false;
double g_tp1_price        = 0.0;

// H1 trailing: last H1 bar time
datetime g_lastTrailBarTime = 0;  // Last bar time for dynamic TF trailing

// Objects
string OBJ_TP1_LINE = "TP1_LINE";

// Button names
string BTN_GRIDB_BUY   = "Btn_GridB_Buy";
string BTN_GRIDB_SELL  = "Btn_GridB_Sell";
string BTN_GRIDC_BUY   = "Btn_GridC_Buy";
string BTN_GRIDC_SELL  = "Btn_GridC_Sell";
string BTN_MKT_BUY     = "Btn_MarketBuy";
string BTN_MKT_SELL    = "Btn_MarketSell";
string BTN_ENTRY       = "Btn_Entry";
string BTN_TRAIL       = "Btn_Trail";
string BTN_HALF_POS    = "Btn_HalfPos";
string BTN_HALF_ALL    = "Btn_HalfAll";
string BTN_SWITCH      = "Btn_Switch";
string BTN_CLOSEALL    = "Btn_CloseAll";

// last used entry mode for Switch
ENUM_ORDER_TYPE g_last_batch_mode = ORDER_TYPE_BUY;
bool g_last_use_auto   = true;
bool g_last_use_bottom = false;

//─────────────────────────────────────────────────────────────
// Utils
//─────────────────────────────────────────────────────────────
int DigitsCount(){ return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double TickSize()
{
   double v=0.0;
   SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, v);
   return (v>0.0 ? v : _Point);
}

double PipSize()
{
   int d = DigitsCount();
   if(d==5 || d==3) return 10.0*_Point;
   if(d==4 || d==2) return  1.0*_Point;
   return TickSize();
}

double RoundToTick(double price)
{
   double ts = TickSize();
   if(ts<=0.0) ts = _Point;
   return MathRound(price/ts)*ts;
}

string ToUpperStr(string s){ StringToUpper(s); return s; }

int GetAutoLegs()
{
   switch(AutoLegsMode)
   {
      case AL_2:  return 2;  case AL_3:  return 3;  case AL_4:  return 4;  case AL_5:  return 5;
      case AL_6:  return 6;  case AL_7:  return 7;  case AL_8:  return 8;  case AL_9:  return 9;
      case AL_10: return 10; case AL_11: return 11; case AL_12: return 12; case AL_13: return 13;
      case AL_14: return 14; case AL_15: return 15; case AL_16: return 16; case AL_17: return 17;
      case AL_18: return 18; case AL_19: return 19; case AL_20: return 20;
   }
   return 3;
}

double SpacingStepFixed()
{
   string u = spacing_unit;
   StringToUpper(u);
   if(u=="POINTS") return spacing_value*_Point;
   if(u=="TICKS")  return spacing_value*TickSize();
   if(u=="PIPS")   return spacing_value*PipSize();
   return spacing_value; // PRICE
}

double VolumeMin()
{
   double v=0.0;
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, v);
   return (v>0.0 ? v : 0.01);
}

double VolumeStep()
{
   double v=0.0;
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, v);
   return (v>0.0 ? v : 0.01);
}

double NormalizeLot(double lot)
{
   double step = VolumeStep();
   double minv = VolumeMin();

   if(lot <= 0.0) return 0.0;
   if(lot < minv) lot = minv;

   double n = MathFloor(lot/step + 1e-8);
   double res = n * step;
   if(res < minv) res = minv;
   return res;
}

bool SymbolIsSpecialBaseLot(const string sym)
{
   string s = sym; StringToUpper(s);
   // gold/silver/btc (broad match)
   if(StringFind(s, "XAU") >= 0) return true;
   if(StringFind(s, "XAG") >= 0) return true;
   if(StringFind(s, "BTC") >= 0) return true;
   return false;
}

double ResolveBaseLotBySymbol()
{
   // Use configurable base lots from input parameters
   string s = _Symbol; 
   StringToUpper(s);
   
   // Gold (XAU)
   if(StringFind(s, "XAU") >= 0) return NormalizeLot(BaseLot_Gold);
   
   // Silver (XAG)
   if(StringFind(s, "XAG") >= 0) return NormalizeLot(BaseLot_Silver);
   
   // Bitcoin (BTC)
   if(StringFind(s, "BTC") >= 0) return NormalizeLot(BaseLot_Bitcoin);
   
   // Others
   return NormalizeLot(BaseLot_Others);
}

double EnsureStopsLevelAway(double ref_price, double target_price, bool is_buy_side)
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops<=0) return RoundToTick(target_price);

   double min_gap = stops*_Point;
   if(is_buy_side)
   {
      // SL must be at least min_gap below Bid for buy
      if(target_price > ref_price - min_gap) target_price = ref_price - min_gap;
   }
   else
   {
      // SL must be at least min_gap above Ask for sell
      if(target_price < ref_price + min_gap) target_price = ref_price + min_gap;
   }
   return RoundToTick(target_price);
}

double GetStopMult()
{
   switch(StopMultMode)
   {
      case SM_0_25:   return 0.25;
      case SM_0_5:    return 0.5;
      case SM_1_0:    return 1.0;
      case SM_1_5:    return 1.5;
      case SM_CUSTOM: return (StopMultCustom > 0.0 ? StopMultCustom : 0.5);
   }
   return 0.5;
}

double GetATR(string sym, ENUM_TIMEFRAMES tf, int period)
{
   int handle = iATR(sym, tf, period);
   if(handle == INVALID_HANDLE) return TickSize();

   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, 0, 1, buffer) < 1) return TickSize();
   return buffer[0];
}

// Get one timeframe level above current chart timeframe for trailing
ENUM_TIMEFRAMES GetTrailingTimeframe()
{
   ENUM_TIMEFRAMES chart_tf = (ENUM_TIMEFRAMES)_Period;
   
   // Map: current TF -> one level above
   switch(chart_tf)
   {
      case PERIOD_M1:  return PERIOD_M5;
      case PERIOD_M2:  return PERIOD_M5;
      case PERIOD_M3:  return PERIOD_M5;
      case PERIOD_M4:  return PERIOD_M5;
      case PERIOD_M5:  return PERIOD_M15;
      case PERIOD_M6:  return PERIOD_M15;
      case PERIOD_M10: return PERIOD_M15;
      case PERIOD_M12: return PERIOD_M15;
      case PERIOD_M15: return PERIOD_M30;
      case PERIOD_M20: return PERIOD_M30;
      case PERIOD_M30: return PERIOD_H1;
      case PERIOD_H1:  return PERIOD_H4;
      case PERIOD_H2:  return PERIOD_H4;
      case PERIOD_H3:  return PERIOD_H4;
      case PERIOD_H4:  return PERIOD_D1;
      case PERIOD_H6:  return PERIOD_D1;
      case PERIOD_H8:  return PERIOD_D1;
      case PERIOD_H12: return PERIOD_D1;
      case PERIOD_D1:  return PERIOD_W1;
      case PERIOD_W1:  return PERIOD_MN1;
      case PERIOD_MN1: return PERIOD_MN1; // Stay at MN1
      default:         return PERIOD_H1;  // Fallback to H1
   }
}

// Auto lots: base lot resolve with MOBILE LOT PRIORITY
double GetFirstGridLotRaw()
{
   // ★ PRIORITY 1: Mobile/external lot (highest priority)
   // BUT ONLY if mobile lot > 0.02 (ignore small mobile positions)
   if(g_mobile_base_lot > 0.02)
   {
      PrintFormat("Using mobile lot %.2f as base (mobile lot > 0.02)", g_mobile_base_lot);
      return g_mobile_base_lot;
   }
   
   // ★ PRIORITY 2: UseFirstLotMode (symbol default)
   if(UseFirstLotMode)
   {
      // Use symbol default base lot (Gold/Silver/BTC: 0.02, others: 0.30)
      return ResolveBaseLotBySymbol();
   }

   // ★ PRIORITY 3: Total lot mode
   int n = GetAutoLegs();
   if(!UseFirstLotMode && AutoTotalLots > 0.0 && n > 0)
   {
      double wsum = 0.0;
      for(int i=0;i<n;i++) wsum += MathPow(AutoLotRatio, i);
      if(wsum > 0.0) return AutoTotalLots * (1.0 / wsum);
   }

   // fallback
   return ResolveBaseLotBySymbol();
}

double GetResolvedMarketLot()
{
   double raw = GetFirstGridLotRaw();
   if(raw <= 0.0) raw = VolumeMin();
   return NormalizeLot(raw);
}

//─────────────────────────────────────────────────────────────
// Risk calc helpers
//─────────────────────────────────────────────────────────────
double AccountRiskCapMoney()
{
   double pct = RiskCapPercent;
   if(pct < 0.0) pct = 0.0;
   if(pct > 100.0) pct = 100.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return eq * (pct/100.0);
}

// returns positive money amount (worst-loss at SL), or 0 if cannot calc
double CalcLossAtSL(ENUM_ORDER_TYPE side, double volume, double price_open, double sl_price)
{
   if(volume <= 0.0) return 0.0;
   if(sl_price <= 0.0 || price_open <= 0.0) return 0.0;

   double profit = 0.0;
   ENUM_ORDER_TYPE ot = side;
   // for existing positions, use BUY/SELL
   if(ot != ORDER_TYPE_BUY && ot != ORDER_TYPE_SELL) return 0.0;

   if(!OrderCalcProfit(ot, _Symbol, volume, price_open, sl_price, profit))
      return 0.0;

   // if profit is negative => loss
   if(profit >= 0.0) return 0.0;
   return -profit;
}

// planned worst-loss for a batch (market+limits) at computed SL
double PlannedBatchWorstLoss(bool is_buy_batch, const double &lots[], int last_index, double step, double base_price, double sl_price, bool include_market)
{
   double totalLoss = 0.0;
   for(int i=0; i<=last_index; ++i)
   {
      if(lots[i] <= 0.0) continue;

      double entry = 0.0;
      if(i==0 && include_market)
         entry = base_price; // current ask/bid snapshot
      else
         entry = is_buy_batch ? (base_price - step*i) : (base_price + step*i);

      entry = RoundToTick(entry);

      double loss = CalcLossAtSL(is_buy_batch ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lots[i], entry, sl_price);
      totalLoss += loss;
   }
   return totalLoss;
}

// current worst-loss at SL for open positions + pending orders (our magics) on this symbol
double CurrentWorstLossAtTargetSL()
{
   if(!UseRiskCapPercent) return 0.0;
   if(!g_has_target_sl || g_target_sl_price<=0.0) return 0.0;

   double sl = g_target_sl_price;
   double totalLoss = 0.0;

   // open positions
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long mag = PositionGetInteger(POSITION_MAGIC);
      if(mag != MagicGrid && mag != MagicMarket) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool is_buy = (pt == POSITION_TYPE_BUY);

      // only evaluate positions consistent with the batch direction / SL logic
      if(is_buy != g_batch_is_buy) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double openp = PositionGetDouble(POSITION_PRICE_OPEN);

      totalLoss += CalcLossAtSL(is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, vol, openp, sl);
   }

   // pending orders
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong oticket = OrderGetTicket(i);
      if(!OrderSelect(oticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      long mag = OrderGetInteger(ORDER_MAGIC);
      if(mag != MagicGrid && mag != MagicMarket) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;

      bool is_buy_limit = (type == ORDER_TYPE_BUY_LIMIT);
      if(is_buy_limit != g_batch_is_buy) continue;

      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);

      totalLoss += CalcLossAtSL(is_buy_limit ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, vol, price, sl);
   }

   return totalLoss;
}

void EmergencyRiskCloseIfNeeded()
{
   if(!UseRiskCapPercent) return;
   double cap = AccountRiskCapMoney();
   if(cap <= 0.0) return;

   double cur = CurrentWorstLossAtTargetSL();
   if(cur <= 0.0) return;

   if(cur > cap)
   {
      PrintFormat("RISK CAP TRIGGER: worstLoss %.2f > cap %.2f (%.2f%%). Emergency close & delete pending.",
                  cur, cap, RiskCapPercent);

      // close + delete
      // (reuse below helpers)
      // We DO NOT reset g_target_sl_price here; we reset after clearing.
      // Close all
      for(int i=PositionsTotal()-1; i>=0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         long mag = PositionGetInteger(POSITION_MAGIC);
         if(mag != MagicGrid && mag != MagicMarket) continue;

         trade.PositionClose(ticket);
         Sleep(80);
      }
      for(int i=OrdersTotal()-1; i>=0; --i)
      {
         ulong ticket = OrderGetTicket(i);
         if(!OrderSelect(ticket)) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

         long mag = OrderGetInteger(ORDER_MAGIC);
         if(mag != MagicGrid && mag != MagicMarket) continue;

         trade.OrderDelete(ticket);
         Sleep(60);
      }

      g_has_target_sl = false;
      g_has_tp = false;
      g_tp1_done = false;
      ObjectDelete(0, OBJ_TP1_LINE);
   }
}

//─────────────────────────────────────────────────────────────
// 50% Close helpers (buttons)
//─────────────────────────────────────────────────────────────
void CloseHalfEachPositionForSymbol(const string sym)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      if(vol <= 0.0) continue;

      double half = NormalizeLot(vol * 0.5);
      if(half <= 0.0 || half >= vol) continue;

      bool ok = trade.PositionClosePartial(ticket, half);
      if(!ok)
         PrintFormat("PositionClosePartial(half each) failed [%I64u]: %s", ticket, trade.ResultRetcodeDescription());
      Sleep(80);
   }
}

void CloseHalfTotalForSymbol(const string sym)
{
   double total = 0.0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      total += PositionGetDouble(POSITION_VOLUME);
   }

   double target = NormalizeLot(total * 0.5);
   if(target <= 0.0) return;

   for(int i=PositionsTotal()-1; i>=0 && target>0.0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      if(vol <= 0.0) continue;

      double cut = MathMin(vol, target);
      cut = NormalizeLot(cut);
      if(cut <= 0.0) continue;

      if(cut >= vol - VolumeStep()*0.5)
      {
         bool ok = trade.PositionClose(ticket);
         if(!ok) PrintFormat("PositionClose(half total -> full) failed [%I64u]: %s", ticket, trade.ResultRetcodeDescription());
      }
      else
      {
         bool ok = trade.PositionClosePartial(ticket, cut);
         if(!ok) PrintFormat("PositionClosePartial(half total) failed [%I64u]: %s", ticket, trade.ResultRetcodeDescription());
      }

      target -= cut;
      Sleep(80);
   }
}

//─────────────────────────────────────────────────────────────
// Unified SL apply (grid + market positions)
// NOTE: Mobile/external positions are EXCLUDED from SL application
//       to prevent immediate liquidation when grid is built
//─────────────────────────────────────────────────────────────
void ApplyUnifiedSLToSymbolPositions(const string sym)
{
   if(!g_has_target_sl) return;

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      long mag = PositionGetInteger(POSITION_MAGIC);
      
      // ★ ONLY apply SL to OUR positions (MagicGrid or MagicMarket)
      // Skip mobile/external positions to prevent immediate liquidation
      if(mag != MagicGrid && mag != MagicMarket) continue;

      bool is_buy_side = g_batch_is_buy;
      double cur_price = is_buy_side ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);

      double desired = EnsureStopsLevelAway(cur_price, g_target_sl_price, is_buy_side);
      desired = RoundToTick(desired);

      double cur_sl = PositionGetDouble(POSITION_SL);
      if(MathAbs(cur_sl - desired) > (TickSize()*0.1))
         trade.PositionModify(ticket, desired, PositionGetDouble(POSITION_TP));
   }
}

//─────────────────────────────────────────────────────────────
// P/L helpers
//─────────────────────────────────────────────────────────────
double TotalProfitForSymbol(const string sym)
{
   double total = 0.0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      total += PositionGetDouble(POSITION_PROFIT);
   }
   return total;
}

void CloseAllPositionsForSymbol(const string sym)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      bool ok = trade.PositionClose(ticket);
      if(!ok)
         PrintFormat("PositionClose failed [%I64u]: %s", ticket, trade.ResultRetcodeDescription());
      Sleep(80);
   }
}

void DeleteAllPendingOrdersForSymbol(const string sym)
{
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;

      bool ok = trade.OrderDelete(ticket);
      if(!ok)
         PrintFormat("OrderDelete failed [%I64u]: %s", ticket, trade.ResultRetcodeDescription());
      Sleep(80);
   }
}

void ResetTPState()
{
   g_has_tp          = false;
   g_tp_price        = 0.0;
   g_tp_dist_init    = 0.0;
   g_tp_dist_current = 0.0;
   g_atr_entry_h1    = 0.0;

   g_tp1_done        = false;
   g_tp1_price       = 0.0;
}

void CheckAmountExit()
{
   double totalP = TotalProfitForSymbol(_Symbol);

   if(UseLossCut && MaxLossAmount > 0.0 && totalP <= -MaxLossAmount)
   {
      PrintFormat("LossCut: %s profit %.2f <= -%.2f -> close all & delete pending",
                  _Symbol, totalP, MaxLossAmount);
      CloseAllPositionsForSymbol(_Symbol);
      DeleteAllPendingOrdersForSymbol(_Symbol);
      g_has_target_sl = false;
      ResetTPState();
      ObjectDelete(0, OBJ_TP1_LINE);
      return;
   }

   if(UseProfitTake && TargetProfitAmount > 0.0 && totalP >= TargetProfitAmount)
   {
      PrintFormat("TakeProfit: %s profit %.2f >= %.2f -> close all & delete pending",
                  _Symbol, totalP, TargetProfitAmount);
      CloseAllPositionsForSymbol(_Symbol);
      DeleteAllPendingOrdersForSymbol(_Symbol);
      g_has_target_sl = false;
      ResetTPState();
      ObjectDelete(0, OBJ_TP1_LINE);
      return;
   }
}

//─────────────────────────────────────────────────────────────
// Server TP / TP1 management
//─────────────────────────────────────────────────────────────
struct PosItem
{
   ulong  ticket;
   double vol;
   double open_price;
   long   type;      // POSITION_TYPE_BUY / POSITION_TYPE_SELL
   long   magic;
};

bool CollectPositionsForTP(const string sym, PosItem &arr[], int &count, long &sideType)
{
   count = 0;
   sideType = -1;
   ArrayResize(arr, 0);

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      long mag = PositionGetInteger(POSITION_MAGIC);
      if(mag != MagicGrid && mag != MagicMarket) continue;

      long ptype = PositionGetInteger(POSITION_TYPE);

      // allow only one side for safety
      if(sideType == -1) sideType = ptype;
      if(ptype != sideType) continue;

      PosItem it;
      it.ticket     = ticket;
      it.vol        = PositionGetDouble(POSITION_VOLUME);
      it.open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      it.type       = ptype;
      it.magic      = mag;

      ArrayResize(arr, count+1);
      arr[count] = it;
      count++;
   }

   return (count > 0 && sideType != -1);
}

void SortForAdvantage(PosItem &arr[], int count, bool is_buy_batch)
{
   // Advantageous positions:
   // BUY  -> higher open price first
   // SELL -> lower open price first
   for(int i=0;i<count-1;i++)
   {
      for(int j=i+1;j<count;j++)
      {
         bool swap=false;
         if(is_buy_batch)
         {
            if(arr[j].open_price > arr[i].open_price) swap=true;
         }
         else
         {
            if(arr[j].open_price < arr[i].open_price) swap=true;
         }
         if(swap)
         {
            PosItem tmp=arr[i];
            arr[i]=arr[j];
            arr[j]=tmp;
         }
      }
   }
}

bool ComputeWeightedAvgPriceAndVolume(const PosItem &arr[], int count, double &avg, double &totalVol)
{
   avg=0.0; totalVol=0.0;
   double wsum=0.0;
   for(int i=0;i<count;i++)
   {
      if(arr[i].vol <= 0.0) continue;
      totalVol += arr[i].vol;
      wsum += arr[i].open_price * arr[i].vol;
   }
   if(totalVol <= 0.0) return false;
   avg = wsum / totalVol;
   return true;
}

double ClampTPDistanceByATR(double dist_init)
{
   if(!UseServerTP) return dist_init;
   if(g_atr_entry_h1 <= 0.0) return dist_init;

   double atr_now = GetATR(_Symbol, PERIOD_H1, ATR_H1_Period);
   if(atr_now <= 0.0) return dist_init;

   // only act when ATR expanded enough
   if(atr_now <= g_atr_entry_h1 * ATR_Expand_Ratio)
      return dist_init;

   double dist_atr = atr_now * ATR_TP_Mult;

   // tighten only (do not expand)
   return MathMin(dist_init, dist_atr);
}

bool ShouldUpdateTP(double new_tp, double cur_tp)
{
   double ts = TickSize();
   double minGap = MathMax(ts, TP_MinUpdateTickGap * ts);
   return (MathAbs(new_tp - cur_tp) >= minGap);
}

void ApplyServerTPToAdvantagePositions(const string sym, bool is_buy_batch, double tp_price)
{
   if(!UseServerTP) return;
   if(tp_price <= 0.0) return;

   PosItem pos[];
   int count=0;
   long sideType=-1;
   if(!CollectPositionsForTP(sym, pos, count, sideType)) return;

   if(is_buy_batch && sideType != POSITION_TYPE_BUY) return;
   if(!is_buy_batch && sideType != POSITION_TYPE_SELL) return;

   double avg=0.0, totalVol=0.0;
   if(!ComputeWeightedAvgPriceAndVolume(pos, count, avg, totalVol)) return;

   double pct = TP_PartialPercent;
   if(pct < 0.0) pct = 0.0;
   if(pct > 100.0) pct = 100.0;

   double targetVol = NormalizeLot(totalVol * (pct/100.0));
   if(targetVol <= 0.0) return;

   SortForAdvantage(pos, count, is_buy_batch);

   double remain = targetVol;

   for(int i=0;i<count;i++)
   {
      if(!PositionSelectByTicket(pos[i].ticket)) continue;

      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);

      double set_tp = 0.0;
      if(remain > 0.0)
      {
         set_tp = tp_price;
         remain -= pos[i].vol; // approximate by whole position
      }
      else
      {
         set_tp = 0.0;
      }

      if(ShouldUpdateTP(set_tp, cur_tp))
      {
         bool ok = trade.PositionModify(pos[i].ticket, cur_sl, set_tp);
         if(!ok)
            PrintFormat("PositionModify(TP0) failed [%I64u]: %s", pos[i].ticket, trade.ResultRetcodeDescription());
         Sleep(40);
      }
   }
}

double ComputeTP1Buffer()
{
   double atr_h1 = GetATR(_Symbol, PERIOD_H1, ATR_H1_Period);
   double buf1   = atr_h1 * TP1_Buffer_ATR_Mult;
   double buf2   = TickSize() * TP1_Buffer_MinTicks;
   double buf    = MathMax(buf1, buf2);
   return (buf > 0.0 ? buf : TickSize()*TP1_Buffer_MinTicks);
}

double ComputeTP1PriceFromTP0(bool is_buy_batch, double tp0_price)
{
   double buf = ComputeTP1Buffer();
   double tp1 = is_buy_batch ? (tp0_price - buf) : (tp0_price + buf);
   return RoundToTick(tp1);
}

void UpdateTP1Line()
{
   if(!ShowTP1Line)
   {
      ObjectDelete(0, OBJ_TP1_LINE);
      return;
   }
   if(!UseTP1_PreClose || !UseServerTP || !g_has_tp || g_tp1_done || g_tp_price<=0.0)
   {
      ObjectDelete(0, OBJ_TP1_LINE);
      return;
   }

   g_tp1_price = ComputeTP1PriceFromTP0(g_batch_is_buy, g_tp_price);

   if(ObjectFind(0, OBJ_TP1_LINE) == -1)
   {
      ObjectCreate(0, OBJ_TP1_LINE, OBJ_HLINE, 0, 0, g_tp1_price);
      ObjectSetInteger(0, OBJ_TP1_LINE, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, OBJ_TP1_LINE, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, OBJ_TP1_LINE, OBJPROP_COLOR, clrGold);
      ObjectSetString (0, OBJ_TP1_LINE, OBJPROP_TEXT, "TP1 (Pre-Close 50%)");
   }
   else
   {
      ObjectSetDouble(0, OBJ_TP1_LINE, OBJPROP_PRICE, g_tp1_price);
   }
}

void RebuildServerTP(bool force=false)
{
   if(!UseServerTP) return;
   if(!g_has_tp && !force) return;
   if(g_tp1_done) return; // after TP1 we stop TP0 management

   PosItem pos[];
   int count=0;
   long sideType=-1;
   if(!CollectPositionsForTP(_Symbol, pos, count, sideType)) return;

   bool is_buy_batch = g_batch_is_buy;
   if(is_buy_batch && sideType != POSITION_TYPE_BUY) return;
   if(!is_buy_batch && sideType != POSITION_TYPE_SELL) return;

   double avg=0.0, totalVol=0.0;
   if(!ComputeWeightedAvgPriceAndVolume(pos, count, avg, totalVol)) return;

   double dist = g_tp_dist_init;
   if(dist <= 0.0) return;

   double dist_eff = ClampTPDistanceByATR(dist);

   // only allow tightening (never expand)
   if(g_tp_dist_current > 0.0)
      dist_eff = MathMin(g_tp_dist_current, dist_eff);

   double tp_new = is_buy_batch ? (avg + dist_eff) : (avg - dist_eff);
   tp_new = RoundToTick(tp_new);

   if(!g_has_tp || force || ShouldUpdateTP(tp_new, g_tp_price))
   {
      g_tp_price = tp_new;
      g_tp_dist_current = dist_eff;
      g_has_tp = true;

      ApplyServerTPToAdvantagePositions(_Symbol, is_buy_batch, g_tp_price);

      PrintFormat("TP0 updated: side=%s avg=%.5f dist=%.5f tp0=%.5f (initDist=%.5f, atrEntry=%.5f)",
                  (is_buy_batch?"BUY":"SELL"), avg, g_tp_dist_current, g_tp_price, g_tp_dist_init, g_atr_entry_h1);
   }

   UpdateTP1Line();
}

void ClearAllTPOnSymbol(const string sym)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      long mag = PositionGetInteger(POSITION_MAGIC);
      if(mag != MagicGrid && mag != MagicMarket) continue;

      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);

      if(cur_tp != 0.0)
      {
         bool ok = trade.PositionModify(ticket, cur_sl, 0.0);
         if(!ok)
            PrintFormat("Clear TP failed [%I64u]: %s", ticket, trade.ResultRetcodeDescription());
         Sleep(40);
      }
   }
}

bool CloseAdvantagePercentForSymbol(const string sym, bool is_buy_batch, double percent)
{
   PosItem pos[];
   int count=0;
   long sideType=-1;
   if(!CollectPositionsForTP(sym, pos, count, sideType)) return false;

   if(is_buy_batch && sideType != POSITION_TYPE_BUY) return false;
   if(!is_buy_batch && sideType != POSITION_TYPE_SELL) return false;

   double avg=0.0, totalVol=0.0;
   if(!ComputeWeightedAvgPriceAndVolume(pos, count, avg, totalVol)) return false;

   double pct = percent;
   if(pct < 0.0) pct = 0.0;
   if(pct > 100.0) pct = 100.0;

   double targetVol = NormalizeLot(totalVol * (pct/100.0));
   if(targetVol <= 0.0) return false;

   SortForAdvantage(pos, count, is_buy_batch);

   double remain = targetVol;

   for(int i=0;i<count && remain>0.0;i++)
   {
      if(!PositionSelectByTicket(pos[i].ticket)) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      if(vol <= 0.0) continue;

      double cut = MathMin(vol, remain);
      cut = NormalizeLot(cut);
      if(cut <= 0.0) break;

      bool ok=false;

      if(cut >= vol - VolumeStep()*0.5)
      {
         ok = trade.PositionClose(pos[i].ticket);
         if(!ok)
            PrintFormat("TP1 PositionClose(full) failed [%I64u]: %s", pos[i].ticket, trade.ResultRetcodeDescription());
      }
      else
      {
         ok = trade.PositionClosePartial(pos[i].ticket, cut);
         if(!ok)
            PrintFormat("TP1 PositionClosePartial failed [%I64u]: %s", pos[i].ticket, trade.ResultRetcodeDescription());
      }

      if(ok) remain -= cut;
      Sleep(80);
   }

   return true;
}

bool IsTP1Triggered()
{
   if(!UseTP1_PreClose) return false;
   if(!UseServerTP || !g_has_tp) return false;
   if(g_tp1_done) return false;
   if(g_tp_price <= 0.0) return false;

   g_tp1_price = ComputeTP1PriceFromTP0(g_batch_is_buy, g_tp_price);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_batch_is_buy)
      return (bid >= g_tp1_price);
   else
      return (ask <= g_tp1_price);
}

void ExecuteTP1Flow()
{
   if(g_tp1_done) return;

   bool ok = CloseAdvantagePercentForSymbol(_Symbol, g_batch_is_buy, TP1_ClosePercent);

   if(ok)
   {
      PrintFormat("TP1 executed: closed %.1f%% advantage-first, now removing TP0 to prevent full exit.", TP1_ClosePercent);

      g_tp1_done = true;

      if(RemoveAllTP_AfterTP1)
         ClearAllTPOnSymbol(_Symbol);

      g_has_tp = false;
      g_tp_price = 0.0;
      g_tp_dist_current = 0.0;

      ObjectDelete(0, OBJ_TP1_LINE);

      if(AutoArmHybridTrailing_AfterTP1)
      {
         trailingEnabled = true;
         Print("Hybrid Trailing auto-armed after TP1.");
      }
   }
}

//─────────────────────────────────────────────────────────────
// Button helpers
//─────────────────────────────────────────────────────────────
void CreateButton(const string name, int x, int y, int w, int h, const string text, color bg, int fsz=10)
{
   if(ObjectFind(0, name)==-1)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE,     w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,     h);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fsz);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,   bg);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrBlack);
      ObjectSetString (0, name, OBJPROP_TEXT,      text);
   }
}

void UpdateTrailButtonText()
{
   if(ObjectFind(0, BTN_TRAIL) != -1)
      ObjectSetString(0, BTN_TRAIL, OBJPROP_TEXT, trailingEnabled ? "Trailing ON" : "Trailing OFF");
}

string OrderTypeShort(ENUM_ORDER_TYPE ot)
{
   switch(ot)
   {
      case ORDER_TYPE_BUY:        return "BUY";
      case ORDER_TYPE_SELL:       return "SELL";
      case ORDER_TYPE_BUY_LIMIT:  return "BUY_LIMIT";
      case ORDER_TYPE_SELL_LIMIT: return "SELL_LIMIT";
      default:                    return "UNKNOWN";
   }
}

string SpacingModeToString()
{
   switch(SpacingMode)
   {
      case SP_FIXED:  return "FIXED";
      case SP_SPREAD: return "SPREAD";
      case SP_ATR:    return "ATR";
   }
   return "UNKNOWN";
}

void ShowGridInfo()
{
   int n = GetAutoLegs();
   if(n <= 0 || n > 20)
   {
      Comment("Warning: AutoLegs must be 1..20");
      return;
   }

   double lots[20];
   ArrayInitialize(lots, 0.0);

   string autoModeStr;
   if(UseFirstLotMode)
   {
      double baseLot = ResolveBaseLotBySymbol();
      autoModeStr = StringFormat("FirstLot(DefaultBySymbol=%.2f)", baseLot);
      for(int i=0; i<n; ++i)
      {
         double rawLot = baseLot * MathPow(AutoLotRatio, i);
         lots[i] = NormalizeLot(rawLot);
      }
   }
   else
   {
      if(AutoTotalLots <= 0.0)
      {
         Comment("Warning: UseFirstLotMode=false but AutoTotalLots <= 0");
         return;
      }
      autoModeStr = StringFormat("TotalLot (Sum=%.2f)", AutoTotalLots);

      double weights[20];
      double wsum = 0.0;
      for(int i=0; i<n; ++i)
      {
         weights[i] = MathPow(AutoLotRatio, i);
         wsum += weights[i];
      }
      if(wsum <= 0.0)
      {
         Comment("Warning: weight sum = 0");
         return;
      }
      for(int i=0; i<n; ++i)
      {
         double rawLot = AutoTotalLots * (weights[i] / wsum);
         lots[i] = NormalizeLot(rawLot);
      }
   }

   double totalLots = 0.0;
   string seq = "";
   for(int i=0; i<n; ++i)
   {
      if(lots[i] <= 0.0) continue;
      totalLots += lots[i];
      if(seq != "") seq += ", ";
      seq += DoubleToString(lots[i], 2);
   }

   string unitLabel = ToUpperStr(spacing_unit);
   string manualInfo = StringFormat("[Manual] Spacing: %s %.2f (manual buttons removed)", unitLabel, spacing_value);

   string autoInfo = StringFormat("[Auto Grid] N=%d, Ratio=%.2f, Mode=%s, SpacingMode=%s",
                                  n, AutoLotRatio, autoModeStr, SpacingModeToString());

   string bottomInfo = StringFormat("[Bottom Grid] N=%d, BottomGridPrice=%.5f (0=auto by %d bars)",
                                    n, BottomGridPrice, BottomLookback);

   string slInfo = StringFormat("[SL] StopMult=%.2f (from last limit)", GetStopMult());

   string lotsInfo = StringFormat("[AutoLots Preview] Sum=%.2f | [%s]", totalLots, seq);

   double capMoney = UseRiskCapPercent ? AccountRiskCapMoney() : 0.0;
   double curWorst = UseRiskCapPercent ? CurrentWorstLossAtTargetSL() : 0.0;
   string riskInfo = UseRiskCapPercent
      ? StringFormat("[RiskCap] %.2f%% (cap=%.2f) | WorstAtSL=%.2f", RiskCapPercent, capMoney, curWorst)
      : "[RiskCap] OFF";

   string tpInfo = "";
   if(UseServerTP)
   {
      tpInfo = StringFormat("[TP0] Partial=%.0f%% InitRatio=%.2f ATRexp=%.2f ATRmult=%.2f TP0=%.5f Dist=%.5f | TP1=%s(%.1f%%) %.5f",
                            TP_PartialPercent, TP_Ratio_Init, ATR_Expand_Ratio, ATR_TP_Mult,
                            (g_has_tp?g_tp_price:0.0), (g_tp_dist_current>0?g_tp_dist_current:0.0),
                            (g_tp1_done?"DONE":"WAIT"), TP1_ClosePercent,
                            (g_tp1_price>0?g_tp1_price:0.0));
   }

   // ★ Mobile position info
   string mobileInfo = "";
   if(g_mobile_base_lot > 0.0)
   {
      mobileInfo = StringFormat("\n[Mobile] Lot=%.2f Ticket=%I64u GridBuilt=%s",
                                g_mobile_base_lot, g_mobile_ticket,
                                (g_mobile_grid_built?"YES":"NO"));
   }

   string msg = manualInfo + "\n" + autoInfo + "\n" + bottomInfo + "\n" + slInfo + "\n" + lotsInfo + "\n" + riskInfo;
   if(tpInfo != "") msg += "\n" + tpInfo;
   if(mobileInfo != "") msg += mobileInfo;

   Comment(msg);
}

void UpdateUIButtonTexts()
{
   int n = GetAutoLegs();

   int lb = BottomLookback;
   if(lb < 1) lb = 1;
   if(lb > 20) lb = 20;  // ★ Limit to max 20 bars for swing high/low

   double lowVal  = 0.0;
   double highVal = 0.0;
   int idxLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW,  lb, 0);
   int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, lb, 0);

   if(idxLow  >= 0) lowVal  = iLow(_Symbol,  PERIOD_CURRENT, idxLow);
   if(idxHigh >= 0) highVal = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);

   int digits = DigitsCount();
   string lowStr  = (lowVal  > 0.0 ? DoubleToString(lowVal,  digits) : "n/a");
   string highStr = (highVal > 0.0 ? DoubleToString(highVal, digits) : "n/a");

   string autoBuyText  = StringFormat("Auto Grid Buy (N=%d)",  n);
   string autoSellText = StringFormat("Auto Grid Sell (N=%d)", n);

   if(ObjectFind(0, BTN_GRIDB_BUY)  != -1) ObjectSetString(0, BTN_GRIDB_BUY,  OBJPROP_TEXT, autoBuyText);
   if(ObjectFind(0, BTN_GRIDB_SELL) != -1) ObjectSetString(0, BTN_GRIDB_SELL, OBJPROP_TEXT, autoSellText);

   string bottomBuyText  = "Bottom Grid Buy (L=" + lowStr  + ")";
   string bottomSellText = "Bottom Grid Sell (H=" + highStr + ")";

   if(ObjectFind(0, BTN_GRIDC_BUY)  != -1) ObjectSetString(0, BTN_GRIDC_BUY,  OBJPROP_TEXT, bottomBuyText);
   if(ObjectFind(0, BTN_GRIDC_SELL) != -1) ObjectSetString(0, BTN_GRIDC_SELL, OBJPROP_TEXT, bottomSellText);

   double mlot = GetResolvedMarketLot();
   string mkt_buy_text  = StringFormat("Market Buy (%.2f)",  mlot);
   string mkt_sell_text = StringFormat("Market Sell (%.2f)", mlot);

   if(ObjectFind(0, BTN_MKT_BUY)  != -1) ObjectSetString(0, BTN_MKT_BUY,  OBJPROP_TEXT, mkt_buy_text);
   if(ObjectFind(0, BTN_MKT_SELL) != -1) ObjectSetString(0, BTN_MKT_SELL, OBJPROP_TEXT, mkt_sell_text);

   if(ObjectFind(0, BTN_HALF_POS) != -1) ObjectSetString(0, BTN_HALF_POS, OBJPROP_TEXT, "Half Close (Each)");
   if(ObjectFind(0, BTN_HALF_ALL) != -1) ObjectSetString(0, BTN_HALF_ALL, OBJPROP_TEXT, "Half Close (Total)");

   string entry_mode = OrderTypeShort(EntryOrderType);
   string entry_text = StringFormat("Entry (%s)", entry_mode);
   if(ObjectFind(0, BTN_ENTRY) != -1) ObjectSetString(0, BTN_ENTRY, OBJPROP_TEXT, entry_text);

   if(ObjectFind(0, BTN_SWITCH) != -1) ObjectSetString(0, BTN_SWITCH, OBJPROP_TEXT, "Switch (Close&Reverse)");
   if(ObjectFind(0, BTN_CLOSEALL) != -1) ObjectSetString(0, BTN_CLOSEALL, OBJPROP_TEXT, "Close All");

   UpdateTrailButtonText();
}

//─────────────────────────────────────────────────────────────
// Spacing helper (Auto / Bottom)
//─────────────────────────────────────────────────────────────
double ComputeStep_Auto(bool useBottomGridFlag, double top_price, int last_index, double bottom_price)
{
   if(useBottomGridFlag && last_index>0 && bottom_price>0.0)
   {
      double diff = bottom_price - top_price;
      return MathAbs(diff / (double)last_index);
   }

   if(SpacingMode == SP_SPREAD)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double spread_points = (ask - bid) / _Point;
      if(spread_points <= 0.0) spread_points = 1.0;
      return spread_points * SpreadMult * _Point;
   }
   else if(SpacingMode == SP_ATR)
   {
      double atr = GetATR(_Symbol, PERIOD_CURRENT, AtrPeriod);
      if(atr <= 0.0) atr = TickSize();
      return atr * AtrMult;
   }

   return SpacingStepFixed();
}

//─────────────────────────────────────────────────────────────
// Core: OpenPositionsEx (with RiskCap pre-check)
//  SL logic is kept EXACTLY as your pasted "last_limit ± step*stopMult".
//─────────────────────────────────────────────────────────────
void OpenPositionsEx(ENUM_ORDER_TYPE mode, bool useAutoLotFlag, bool useBottomGridFlag)
{
   trade.SetExpertMagicNumber(MagicGrid);

   double lots[20] = {
      lot1, lot2, lot3, lot4, lot5, lot6, lot7, lot8, lot9, lot10,
      lot11, lot12, lot13, lot14, lot15, lot16, lot17, lot18, lot19, lot20
   };

   // ★ Check if manual lots have enough non-zero values (at least 2 for grid)
   int manual_nonzero_count = 0;
   for(int i=0; i<20; ++i)
   {
      if(lots[i] > 0.0) manual_nonzero_count++;
   }
   
   // ★ If manual lots insufficient (< 2), force AutoLot mode
   bool force_autolot = (manual_nonzero_count < 2);
   bool effective_autolot = useAutoLotFlag || force_autolot;  // ← Effective flag for later use
   
   if(effective_autolot)
   {
      if(force_autolot)
      {
         PrintFormat("Manual lots insufficient (only %d non-zero) - using AutoLot mode", manual_nonzero_count);
      }
      
      int n = GetAutoLegs();
      if(n > 20) n = 20;
      if(n <= 0)
      {
         Print("AutoLot mode but AutoLegs <= 0");
         return;
      }

      if(UseFirstLotMode)
      {
         // ★ Use GetFirstGridLotRaw() to respect mobile lot priority
         double baseLot = GetFirstGridLotRaw();
         for(int i=0; i<n; ++i)
         {
            double rawLot = baseLot * MathPow(AutoLotRatio, i);
            lots[i] = NormalizeLot(rawLot);
         }
         for(int i=n; i<20; ++i) lots[i] = 0.0;
      }
      else
      {
         double weights[20];
         double wsum = 0.0;
         for(int i=0; i<n; ++i)
         {
            weights[i] = MathPow(AutoLotRatio, i);
            wsum += weights[i];
         }
         if(wsum <= 0.0)
         {
            Print("AutoLot weight sum is 0");
            return;
         }
         for(int i=0; i<n; ++i)
         {
            double rawLot = AutoTotalLots * (weights[i] / wsum);
            lots[i] = NormalizeLot(rawLot);
         }
         for(int i=n; i<20; ++i) lots[i] = 0.0;
      }
   }

   int last_index = -1;
   for(int i=19; i>=0; --i)
   {
      if(lots[i] > 0.0){ last_index=i; break; }
   }
   if(last_index==-1)
   {
      Print("All lots are 0. No orders sent.");
      return;
   }

   int lb = BottomLookback;
   if(lb < 1) lb = 1;
   if(lb > 20) lb = 20;  // ★ Limit to max 20 bars for bottom/top grid

   double stopMult = GetStopMult();

   // New batch => reset TP states
   g_tp1_done = false;
   g_tp1_price = 0.0;
   ObjectDelete(0, OBJ_TP1_LINE);

   // BUY (market + below limits)
   if(mode == ORDER_TYPE_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // ★ Check for mobile position to use its entry price as base
      bool is_buy_mobile = false;
      double mobile_entry_price = 0.0;
      double mobile_lot = 0.0;
      ulong mobile_ticket = 0;
      bool use_mobile_base = false;
      
      if(g_mobile_base_lot > 0.02 && FindExternalPosition(is_buy_mobile, mobile_entry_price, mobile_lot, mobile_ticket))
      {
         if(is_buy_mobile && mobile_entry_price > 0.0)
         {
            use_mobile_base = true;
            PrintFormat("Using mobile BUY position entry price %.5f as grid base (lot %.2f)", mobile_entry_price, mobile_lot);
         }
      }

      double bottom_p = BottomGridPrice;
      if(useBottomGridFlag)
      {
         if(bottom_p <= 0.0)
         {
            int idx = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, lb, 0);
            if(idx >= 0) bottom_p = iLow(_Symbol, PERIOD_CURRENT, idx);
         }
      }

      // ★ Use mobile entry price or ask for step calculation
      double base_for_step = use_mobile_base ? mobile_entry_price : ask;
      double step = effective_autolot
         ? ComputeStep_Auto(useBottomGridFlag, base_for_step, last_index, bottom_p)
         : SpacingStepFixed();

      g_grid_step_used  = step;
      g_grid_last_index = last_index;

      // ★ Use mobile entry price as base for limit orders
      double base_price = use_mobile_base ? mobile_entry_price : ask;
      double last_limit = RoundToTick(base_price - step*last_index);
      
      // ★ For mobile position: use wider SL based on mobile entry price
      // This prevents immediate liquidation of limit orders
      double sl_req;
      if(use_mobile_base)
      {
         // SL below the last limit with extra buffer for mobile positions
         sl_req = RoundToTick(mobile_entry_price - step*(last_index + stopMult*2));
         PrintFormat("Mobile BUY SL: %.5f (mobile entry %.5f - step %.2f * %.1f)", 
                     sl_req, mobile_entry_price, step, (last_index + stopMult*2));
      }
      else
      {
         // Standard SL calculation
         sl_req = RoundToTick(last_limit - step*stopMult);
      }

      // RiskCap pre-check (planned)
      if(UseRiskCapPercent)
      {
         // ★ Use base_price for risk calculation
         double planned = PlannedBatchWorstLoss(true, lots, last_index, step, base_price, sl_req, true);
         double cap = AccountRiskCapMoney();
         if(cap > 0.0 && planned > cap)
         {
            PrintFormat("RISK CAP BLOCKED (BUY): plannedWorstLoss %.2f > cap %.2f (%.2f%%). No orders sent.",
                        planned, cap, RiskCapPercent);
            return;
         }
      }

      g_has_target_sl   = true;
      g_batch_is_buy    = true;
      g_target_sl_price = sl_req;

      // remember last batch for Switch
      g_last_batch_mode = ORDER_TYPE_BUY;
      g_last_use_auto   = useAutoLotFlag;
      g_last_use_bottom = useBottomGridFlag;

      // server TP init state (GridRange-based)
      if(UseServerTP)
      {
         double gridRange = MathAbs(step * (double)last_index);
         g_tp_dist_init    = gridRange * TP_Ratio_Init;   // 70%
         g_tp_dist_current = g_tp_dist_init;
         g_atr_entry_h1    = GetATR(_Symbol, PERIOD_H1, ATR_H1_Period);
         g_has_tp          = true;
      }

      // ★ Only place market order if no mobile position
      if(!use_mobile_base && lots[0] > 0.0)
      {
         bool ok = trade.Buy(lots[0], NULL, 0.0, 0.0, 0.0);
         if(!ok) PrintFormat("Market BUY failed: %s", trade.ResultRetcodeDescription());
         Sleep(120);
         ApplyUnifiedSLToSymbolPositions(_Symbol);
      }
      else if(use_mobile_base)
      {
         PrintFormat("Skipping market order - using mobile position as base (%.2f lot @ %.5f)", mobile_lot, mobile_entry_price);
         ApplyUnifiedSLToSymbolPositions(_Symbol);
      }

      // ★ Place limit orders from base_price
      for(int i=1; i<=last_index; ++i)
      {
         if(lots[i] <= 0.0) continue;
         double price = RoundToTick(base_price - step*i);
         bool ok = trade.BuyLimit(lots[i], price, NULL, g_target_sl_price, 0.0);
         if(!ok) PrintFormat("BuyLimit failed %d: %s", i+1, trade.ResultRetcodeDescription());
         Sleep(120);
      }

      if(UseServerTP) RebuildServerTP(true);

      PrintFormat("BUY batch done. SL=%.10f", g_target_sl_price);
   }
   // SELL (market + above limits)
   else if(mode == ORDER_TYPE_SELL)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // ★ Check for mobile position to use its entry price as base
      bool is_buy_mobile = false;
      double mobile_entry_price = 0.0;
      double mobile_lot = 0.0;
      ulong mobile_ticket = 0;
      bool use_mobile_base = false;
      
      if(g_mobile_base_lot > 0.02 && FindExternalPosition(is_buy_mobile, mobile_entry_price, mobile_lot, mobile_ticket))
      {
         if(!is_buy_mobile && mobile_entry_price > 0.0)
         {
            use_mobile_base = true;
            PrintFormat("Using mobile SELL position entry price %.5f as grid base (lot %.2f)", mobile_entry_price, mobile_lot);
         }
      }

      double top_far = BottomGridPrice;
      if(useBottomGridFlag)
      {
         if(top_far <= 0.0)
         {
            int idx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, lb, 0);
            if(idx >= 0) top_far = iHigh(_Symbol, PERIOD_CURRENT, idx);
         }
      }

      // ★ Use mobile entry price or bid for step calculation
      double base_for_step = use_mobile_base ? mobile_entry_price : bid;
      double step = effective_autolot
         ? ComputeStep_Auto(useBottomGridFlag, base_for_step, last_index, top_far)
         : SpacingStepFixed();

      g_grid_step_used  = step;
      g_grid_last_index = last_index;

      // ★ Use mobile entry price as base for limit orders
      double base_price = use_mobile_base ? mobile_entry_price : bid;
      double last_limit = RoundToTick(base_price + step*last_index);
      
      // ★ For mobile position: use wider SL based on mobile entry price
      // This prevents immediate liquidation of limit orders
      double sl_req;
      if(use_mobile_base)
      {
         // SL above the last limit with extra buffer for mobile positions
         sl_req = RoundToTick(mobile_entry_price + step*(last_index + stopMult*2));
         PrintFormat("Mobile SELL SL: %.5f (mobile entry %.5f + step %.2f * %.1f)", 
                     sl_req, mobile_entry_price, step, (last_index + stopMult*2));
      }
      else
      {
         // Standard SL calculation
         sl_req = RoundToTick(last_limit + step*stopMult);
      }

      // RiskCap pre-check (planned)
      if(UseRiskCapPercent)
      {
         // ★ Use base_price for risk calculation
         double planned = PlannedBatchWorstLoss(false, lots, last_index, step, base_price, sl_req, true);
         double cap = AccountRiskCapMoney();
         if(cap > 0.0 && planned > cap)
         {
            PrintFormat("RISK CAP BLOCKED (SELL): plannedWorstLoss %.2f > cap %.2f (%.2f%%). No orders sent.",
                        planned, cap, RiskCapPercent);
            return;
         }
      }

      g_has_target_sl   = true;
      g_batch_is_buy    = false;
      g_target_sl_price = sl_req;

      // remember last batch for Switch
      g_last_batch_mode = ORDER_TYPE_SELL;
      g_last_use_auto   = useAutoLotFlag;
      g_last_use_bottom = useBottomGridFlag;

      if(UseServerTP)
      {
         double gridRange = MathAbs(step * (double)last_index);
         g_tp_dist_init    = gridRange * TP_Ratio_Init;   // 70%
         g_tp_dist_current = g_tp_dist_init;
         g_atr_entry_h1    = GetATR(_Symbol, PERIOD_H1, ATR_H1_Period);
         g_has_tp          = true;
      }

      // ★ Only place market order if no mobile position
      if(!use_mobile_base && lots[0] > 0.0)
      {
         bool ok = trade.Sell(lots[0], NULL, 0.0, 0.0, 0.0);
         if(!ok) PrintFormat("Market SELL failed: %s", trade.ResultRetcodeDescription());
         Sleep(120);
         ApplyUnifiedSLToSymbolPositions(_Symbol);
      }
      else if(use_mobile_base)
      {
         PrintFormat("Skipping market order - using mobile position as base (%.2f lot @ %.5f)", mobile_lot, mobile_entry_price);
         ApplyUnifiedSLToSymbolPositions(_Symbol);
      }

      // ★ Place limit orders from base_price
      for(int i=1; i<=last_index; ++i)
      {
         if(lots[i] <= 0.0) continue;
         double price = RoundToTick(base_price + step*i);
         bool ok = trade.SellLimit(lots[i], price, NULL, g_target_sl_price, 0.0);
         if(!ok) PrintFormat("SellLimit failed %d: %s", i+1, trade.ResultRetcodeDescription());
         Sleep(120);
      }

      if(UseServerTP) RebuildServerTP(true);

      PrintFormat("SELL batch done. SL=%.10f", g_target_sl_price);
   }
   // Limit-only entry (BUY_LIMIT / SELL_LIMIT)
   else if(mode==ORDER_TYPE_BUY_LIMIT || mode==ORDER_TYPE_SELL_LIMIT)
   {
      if(entry_price <= 0.0)
      {
         Print("Limit mode requires entry_price > 0");
         return;
      }

      double base_price = RoundToTick(entry_price);

      if(mode==ORDER_TYPE_BUY_LIMIT)
      {
         double bottom_p = BottomGridPrice;
         if(useBottomGridFlag)
         {
            if(bottom_p <= 0.0)
            {
               int idx = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, lb, 0);
               if(idx >= 0) bottom_p = iLow(_Symbol, PERIOD_CURRENT, idx);
            }
         }

         double step = effective_autolot
            ? ComputeStep_Auto(useBottomGridFlag, base_price, last_index, bottom_p)
            : SpacingStepFixed();

         g_grid_step_used  = step;
         g_grid_last_index = last_index;

         double last_limit = RoundToTick(base_price - step*last_index);
         double sl_req     = RoundToTick(last_limit - step*stopMult); // ★ 원복 SL 로직

         if(UseRiskCapPercent)
         {
            double planned = PlannedBatchWorstLoss(true, lots, last_index, step, base_price, sl_req, false);
            double cap = AccountRiskCapMoney();
            if(cap > 0.0 && planned > cap)
            {
               PrintFormat("RISK CAP BLOCKED (BUY_LIMIT batch): plannedWorstLoss %.2f > cap %.2f (%.2f%%).",
                           planned, cap, RiskCapPercent);
               return;
            }
         }

         g_has_target_sl   = true;
         g_batch_is_buy    = true;
         g_target_sl_price = sl_req;

         g_last_batch_mode = ORDER_TYPE_BUY;
         g_last_use_auto   = useAutoLotFlag;
         g_last_use_bottom = useBottomGridFlag;

         if(UseServerTP)
         {
            double gridRange = MathAbs(step * (double)last_index);
            g_tp_dist_init    = gridRange * TP_Ratio_Init;
            g_tp_dist_current = g_tp_dist_init;
            g_atr_entry_h1    = GetATR(_Symbol, PERIOD_H1, ATR_H1_Period);
            g_has_tp          = true;
         }

         for(int i=0; i<=last_index; ++i)
         {
            if(lots[i] <= 0.0) continue;
            double price = RoundToTick(base_price - step*i);
            bool ok = trade.BuyLimit(lots[i], price, NULL, g_target_sl_price, 0.0);
            if(!ok) PrintFormat("BUY_LIMIT failed %d: %s", i+1, trade.ResultRetcodeDescription());
            Sleep(120);
         }

         PrintFormat("BUY_LIMIT batch placed. SL=%.10f", g_target_sl_price);
      }
      else // SELL_LIMIT
      {
         double top_far = BottomGridPrice;
         if(useBottomGridFlag)
         {
            if(top_far <= 0.0)
            {
               int idx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, lb, 0);
               if(idx >= 0) top_far = iHigh(_Symbol, PERIOD_CURRENT, idx);
            }
         }

         double step = effective_autolot
            ? ComputeStep_Auto(useBottomGridFlag, base_price, last_index, top_far)
            : SpacingStepFixed();

         g_grid_step_used  = step;
         g_grid_last_index = last_index;

         double last_limit = RoundToTick(base_price + step*last_index);
         double sl_req     = RoundToTick(last_limit + step*stopMult); // ★ 원복 SL 로직

         if(UseRiskCapPercent)
         {
            double planned = PlannedBatchWorstLoss(false, lots, last_index, step, base_price, sl_req, false);
            double cap = AccountRiskCapMoney();
            if(cap > 0.0 && planned > cap)
            {
               PrintFormat("RISK CAP BLOCKED (SELL_LIMIT batch): plannedWorstLoss %.2f > cap %.2f (%.2f%%).",
                           planned, cap, RiskCapPercent);
               return;
            }
         }

         g_has_target_sl   = true;
         g_batch_is_buy    = false;
         g_target_sl_price = sl_req;

         g_last_batch_mode = ORDER_TYPE_SELL;
         g_last_use_auto   = useAutoLotFlag;
         g_last_use_bottom = useBottomGridFlag;

         if(UseServerTP)
         {
            double gridRange = MathAbs(step * (double)last_index);
            g_tp_dist_init    = gridRange * TP_Ratio_Init;
            g_tp_dist_current = g_tp_dist_init;
            g_atr_entry_h1    = GetATR(_Symbol, PERIOD_H1, ATR_H1_Period);
            g_has_tp          = true;
         }

         for(int i=0; i<=last_index; ++i)
         {
            if(lots[i] <= 0.0) continue;
            double price = RoundToTick(base_price + step*i);
            bool ok = trade.SellLimit(lots[i], price, NULL, g_target_sl_price, 0.0);
            if(!ok) PrintFormat("SELL_LIMIT failed %d: %s", i+1, trade.ResultRetcodeDescription());
            Sleep(120);
         }

         PrintFormat("SELL_LIMIT batch placed. SL=%.10f", g_target_sl_price);
      }
   }
   
   // ★ Mark grid as built after successful placement
   if(g_mobile_base_lot > 0.02)
   {
      g_mobile_grid_built = true;
      g_mobile_check_cooldown = 30; // ★ Set 30-tick cooldown (about 3 seconds in fast markets)
      PrintFormat("Grid built for mobile position - cooldown set to 30 ticks");
   }
}

//─────────────────────────────────────────────────────────────
// Market single orders (uses derived first lot)
//─────────────────────────────────────────────────────────────
void MarketBuyOnce()
{
   // ★ FIXED: Check cooldown AND our positions BEFORE routing to grid
   if(g_mobile_base_lot > 0.02 && g_mobile_check_cooldown <= 0 && !HasOurPositionsOrOrders())
   {
      PrintFormat("MarketBuy: Mobile lot %.2f detected (cooldown=0, no our orders) -> routing through Bottom Grid Buy", g_mobile_base_lot);
      OpenPositionsEx(ORDER_TYPE_BUY, true, true);  // ← same as Bottom Grid UI button
      return;
   }
   
   double lot = GetResolvedMarketLot();
   if(lot <= 0.0)
   {
      Print("MarketBuy: lot=0, skip");
      return;
   }

   trade.SetExpertMagicNumber(MagicMarket);

   double sl = 0.0;
   if(g_has_target_sl && g_batch_is_buy) sl = g_target_sl_price;

   bool ok = trade.Buy(lot, NULL, 0.0, sl, 0.0);
   if(!ok) PrintFormat("MarketBuy failed: %s", trade.ResultRetcodeDescription());

   if(UseServerTP && g_has_tp && !g_tp1_done) RebuildServerTP(true);
}

void MarketSellOnce()
{
   // ★ FIXED: Check cooldown AND our positions BEFORE routing to grid
   if(g_mobile_base_lot > 0.02 && g_mobile_check_cooldown <= 0 && !HasOurPositionsOrOrders())
   {
      PrintFormat("MarketSell: Mobile lot %.2f detected (cooldown=0, no our orders) -> routing through Bottom Grid Sell", g_mobile_base_lot);
      OpenPositionsEx(ORDER_TYPE_SELL, true, true);  // ← same as Bottom Grid UI button
      return;
   }
   
   double lot = GetResolvedMarketLot();
   if(lot <= 0.0)
   {
      Print("MarketSell: lot=0, skip");
      return;
   }

   trade.SetExpertMagicNumber(MagicMarket);

   double sl = 0.0;
   if(g_has_target_sl && !g_batch_is_buy) sl = g_target_sl_price;

   bool ok = trade.Sell(lot, NULL, 0.0, sl, 0.0);
   if(!ok) PrintFormat("MarketSell failed: %s", trade.ResultRetcodeDescription());

   if(UseServerTP && g_has_tp && !g_tp1_done) RebuildServerTP(true);
}

void SwitchCloseAndReverse()
{
   // 1) close all + delete pending
   CloseAllPositionsForSymbol(_Symbol);
   DeleteAllPendingOrdersForSymbol(_Symbol);

   // 2) reverse using last batch preferences
   ENUM_ORDER_TYPE rev = (g_last_batch_mode == ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   PrintFormat("Switch: Close&Reverse -> %s (useAuto=%s useBottom=%s)",
               (rev==ORDER_TYPE_BUY?"BUY":"SELL"),
               (g_last_use_auto?"true":"false"),
               (g_last_use_bottom?"true":"false"));

   OpenPositionsEx(rev, g_last_use_auto, g_last_use_bottom);
}

//─────────────────────────────────────────────────────────────
// Lifecycle
//─────────────────────────────────────────────────────────────
int OnInit()
{
   // Initialize mobile position tracking
   g_mobile_base_lot = 0.0;
   g_mobile_ticket = 0;
   g_mobile_grid_built = false;
   g_mobile_check_cooldown = 0;
   
   // UI: make it a bit taller vertically, and keep Switch on ONE line (wider button)
   int W  = 250;
   int H  = 35;
   int x1 = 10;
   int x2 = 10 + W + 12;
   int y1 = 40;
   int dY = 43;      // ★ 위아래 간격 넓힘
   int fsz = 8;      // ★ 글씨 조금 줄임

   CreateButton(BTN_GRIDB_BUY , x1, y1,      W, H, "Auto Grid Buy",  clrLime,   fsz);
   CreateButton(BTN_GRIDB_SELL, x2, y1,      W, H, "Auto Grid Sell", clrOrange, fsz);

   CreateButton(BTN_GRIDC_BUY , x1, y1+dY,   W, H, "Bottom Grid Buy",  clrLime,   fsz);
   CreateButton(BTN_GRIDC_SELL, x2, y1+dY,   W, H, "Bottom Grid Sell", clrOrange, fsz);

   CreateButton(BTN_MKT_BUY ,  x1, y1+dY*2,  W, H, "Market Buy",  clrGreen,  fsz);
   CreateButton(BTN_MKT_SELL,  x2, y1+dY*2,  W, H, "Market Sell", clrTomato, fsz);

   CreateButton(BTN_HALF_POS,  x1, y1+dY*3,  W, H, "Half Close (Each)",  clrSilver, fsz);
   CreateButton(BTN_HALF_ALL,  x2, y1+dY*3,  W, H, "Half Close (Total)", clrSilver, fsz);

   CreateButton(BTN_ENTRY,     x1, y1+dY*4,  W, H, "Entry",        clrDodgerBlue, fsz);
   CreateButton(BTN_TRAIL,     x2, y1+dY*4,  W, H, "Trailing OFF", clrSilver,     fsz);

   // Switch row (one-line wide button) + CloseAll
   int Wwide = (W*2 + 12);
   CreateButton(BTN_SWITCH,    x1, y1+dY*5,  Wwide, H, "Switch (Close&Reverse)", clrKhaki, fsz);
   CreateButton(BTN_CLOSEALL,  x1, y1+dY*6,  Wwide, H, "Close All",              clrLightGray, fsz);

   UpdateUIButtonTexts();
   ShowGridInfo();

   EventSetTimer(MathMax(1, TrailUpdateInterval));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   ObjectDelete(0, BTN_GRIDB_BUY);
   ObjectDelete(0, BTN_GRIDB_SELL);
   ObjectDelete(0, BTN_GRIDC_BUY);
   ObjectDelete(0, BTN_GRIDC_SELL);
   ObjectDelete(0, BTN_MKT_BUY);
   ObjectDelete(0, BTN_MKT_SELL);
   ObjectDelete(0, BTN_HALF_POS);
   ObjectDelete(0, BTN_HALF_ALL);
   ObjectDelete(0, BTN_ENTRY);
   ObjectDelete(0, BTN_TRAIL);
   ObjectDelete(0, BTN_SWITCH);
   ObjectDelete(0, BTN_CLOSEALL);

   ObjectDelete(0, OBJ_TP1_LINE);

   Comment("");
}

//─────────────────────────────────────────────────────────────
// Chart events
//─────────────────────────────────────────────────────────────
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_GRIDB_BUY && !is_ordering)
      {
         is_ordering = true;
         ObjectSetInteger(0, BTN_GRIDB_BUY, OBJPROP_STATE, false);
         OpenPositionsEx(ORDER_TYPE_BUY, true, false);
         is_ordering = false;
      }
      else if(sparam == BTN_GRIDB_SELL && !is_ordering)
      {
         is_ordering = true;
         ObjectSetInteger(0, BTN_GRIDB_SELL, OBJPROP_STATE, false);
         OpenPositionsEx(ORDER_TYPE_SELL, true, false);
         is_ordering = false;
      }
      else if(sparam == BTN_GRIDC_BUY && !is_ordering)
      {
         is_ordering = true;
         ObjectSetInteger(0, BTN_GRIDC_BUY, OBJPROP_STATE, false);
         OpenPositionsEx(ORDER_TYPE_BUY, true, true);
         is_ordering = false;
      }
      else if(sparam == BTN_GRIDC_SELL && !is_ordering)
      {
         is_ordering = true;
         ObjectSetInteger(0, BTN_GRIDC_SELL, OBJPROP_STATE, false);
         OpenPositionsEx(ORDER_TYPE_SELL, true, true);
         is_ordering = false;
      }
      else if(sparam == BTN_MKT_BUY)
      {
         ObjectSetInteger(0, BTN_MKT_BUY, OBJPROP_STATE, false);
         MarketBuyOnce();
      }
      else if(sparam == BTN_MKT_SELL)
      {
         ObjectSetInteger(0, BTN_MKT_SELL, OBJPROP_STATE, false);
         MarketSellOnce();
      }
      else if(sparam == BTN_HALF_POS)
      {
         ObjectSetInteger(0, BTN_HALF_POS, OBJPROP_STATE, false);
         CloseHalfEachPositionForSymbol(_Symbol);
         if(UseServerTP && g_has_tp && !g_tp1_done) RebuildServerTP(true);
      }
      else if(sparam == BTN_HALF_ALL)
      {
         ObjectSetInteger(0, BTN_HALF_ALL, OBJPROP_STATE, false);
         CloseHalfTotalForSymbol(_Symbol);
         if(UseServerTP && g_has_tp && !g_tp1_done) RebuildServerTP(true);
      }
      else if(sparam == BTN_ENTRY && !is_ordering)
      {
         is_ordering = true;
         ObjectSetInteger(0, BTN_ENTRY, OBJPROP_STATE, false);
         OpenPositionsEx(EntryOrderType, UseAutoLot_Default, UseBottomGridPrice_Def);
         is_ordering = false;
      }
      else if(sparam == BTN_TRAIL)
      {
         trailingEnabled = !trailingEnabled;
         UpdateTrailButtonText();
         ObjectSetInteger(0, BTN_TRAIL, OBJPROP_STATE, false);
         Print("Trailing: ", (trailingEnabled ? "ON" : "OFF"));
      }
      else if(sparam == BTN_SWITCH && !is_ordering)
      {
         is_ordering = true;
         ObjectSetInteger(0, BTN_SWITCH, OBJPROP_STATE, false);
         SwitchCloseAndReverse();
         is_ordering = false;
      }
      else if(sparam == BTN_CLOSEALL)
      {
         ObjectSetInteger(0, BTN_CLOSEALL, OBJPROP_STATE, false);
         CloseAllPositionsForSymbol(_Symbol);
         DeleteAllPendingOrdersForSymbol(_Symbol);
         g_has_target_sl = false;
         ResetTPState();
         ObjectDelete(0, OBJ_TP1_LINE);
         
         // Reset mobile position tracking
         g_mobile_base_lot = 0.0;
         g_mobile_ticket = 0;
         g_mobile_grid_built = false;
         g_mobile_check_cooldown = 0;
      }

      ShowGridInfo();
      UpdateUIButtonTexts();
   }
}

//─────────────────────────────────────────────────────────────
// Trade transaction: on new deal -> re-apply SL + rebuild TP0
//─────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&    request,
                        const MqlTradeResult&     result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(StringLen(trans.symbol) && trans.symbol == _Symbol)
      {
         ApplyUnifiedSLToSymbolPositions(_Symbol);

         if(UseServerTP && g_has_tp && !g_tp1_done)
            RebuildServerTP(false);
      }
   }
   
   // ★ Position CLOSE detection: delete all pending limit orders
   if(trans.type == TRADE_TRANSACTION_HISTORY_ADD)
   {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
         if(StringLen(trans.symbol) && trans.symbol == _Symbol)
         {
            // Check if this was a position CLOSE (not entry)
            // Entry deals have position_id that creates new position
            // Close deals have position_id that references closed position
            
            // If no more positions remain with our magic, delete all pending orders
            bool has_our_positions = false;
            for(int i=PositionsTotal()-1; i>=0; --i)
            {
               ulong ticket = PositionGetTicket(i);
               if(!PositionSelectByTicket(ticket)) continue;
               if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               
               long mag = PositionGetInteger(POSITION_MAGIC);
               if(mag == MagicGrid || mag == MagicMarket)
               {
                  has_our_positions = true;
                  break;
               }
            }
            
            // ★ If all positions closed, delete ALL pending limit orders
            if(!has_our_positions)
            {
               int deleted_count = 0;
               for(int i=OrdersTotal()-1; i>=0; --i)
               {
                  ulong ticket = OrderGetTicket(i);
                  if(!OrderSelect(ticket)) continue;
                  if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
                  
                  long mag = OrderGetInteger(ORDER_MAGIC);
                  if(mag == MagicGrid || mag == MagicMarket)
                  {
                     bool ok = trade.OrderDelete(ticket);
                     if(ok) deleted_count++;
                     Sleep(60);
                  }
               }
               
               if(deleted_count > 0)
               {
                  PrintFormat("★ Position liquidated: deleted %d pending limit orders", deleted_count);
                  
                  // Reset states
                  g_has_target_sl = false;
                  ResetTPState();
                  ObjectDelete(0, OBJ_TP1_LINE);
                  
                  // ★ CRITICAL: Reset mobile grid built flag to allow rebuild
                  if(g_mobile_base_lot > 0.02)
                  {
                     g_mobile_grid_built = false;
                     PrintFormat("Grid liquidated - allowing mobile grid rebuild (mobile lot %.2f still detected)", g_mobile_base_lot);
                  }
               }
            }
         }
      }
   }
}

//─────────────────────────────────────────────────────────────
// Mobile/External lot detection (FIXED)
//─────────────────────────────────────────────────────────────
bool FindExternalPosition(bool &is_buy, double &price, double &lot, ulong &ticket)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long mag = PositionGetInteger(POSITION_MAGIC);
      // Skip our own grid/market positions
      if(mag == MagicGrid || mag == MagicMarket) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      is_buy = (pt == POSITION_TYPE_BUY);
      price = PositionGetDouble(POSITION_PRICE_OPEN);
      lot   = PositionGetDouble(POSITION_VOLUME);
      ticket = t;
      return true;
   }
   return false;
}

bool HasOurPositionsOrOrders()
{
   // Check for existing grid/market positions
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long mag = PositionGetInteger(POSITION_MAGIC);
      if(mag == MagicGrid || mag == MagicMarket) return true;
   }
   
   // Check for existing grid/market orders
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong t = OrderGetTicket(i);
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      long mag = OrderGetInteger(ORDER_MAGIC);
      if(mag == MagicGrid || mag == MagicMarket) return true;
   }
   
   return false;
}

// ★ FIXED: Added throttling cooldown mechanism
void CheckAndUpdateMobileLot()
{
   // ★ Decrease cooldown counter each tick
   if(g_mobile_check_cooldown > 0)
   {
      g_mobile_check_cooldown--;
      return; // Skip mobile lot checking during cooldown
   }
   
   bool is_buy = false;
   double price = 0.0;
   double lot = 0.0;
   ulong ticket = 0;
   
   // ★ Check if our grid/orders disappeared (liquidated) - reset build flag
   if(g_mobile_grid_built && !HasOurPositionsOrOrders())
   {
      g_mobile_grid_built = false;
      PrintFormat("EA grid cleared (liquidated?) - allowing mobile grid rebuild");
   }
   
   // Check if mobile position exists
   if(FindExternalPosition(is_buy, price, lot, ticket))
   {
      // Mobile position found
      // ★ ONLY process if lot > 0.02 (ignore small mobile positions)
      if(lot > 0.02)
      {
         // Check if this is a new mobile position (different ticket or first time)
         if(ticket != g_mobile_ticket || g_mobile_base_lot == 0.0)
         {
            g_mobile_base_lot = lot;
            g_mobile_ticket = ticket;
            g_mobile_grid_built = false; // Mark as not built yet
            
            // ★ New mobile position detected - clean up old grid completely
            // Close any remaining EA positions and delete all limit orders
            if(HasOurPositionsOrOrders())
            {
               PrintFormat("New mobile position detected - cleaning up old grid");
               CloseAllPositionsForSymbol(_Symbol);
               DeleteAllPendingOrdersForSymbol(_Symbol);
               g_has_target_sl = false;
               ResetTPState();
               ObjectDelete(0, OBJ_TP1_LINE);
            }
            
            PrintFormat("Mobile position detected (lot > 0.02): Ticket=%I64u, Lot=%.2f, %s @ %.5f", 
                        ticket, lot, (is_buy?"BUY":"SELL"), price);
         }
         
         // ★ FIXED: Auto build grid ONLY if:
         // 1. Grid not built yet
         // 2. No our positions/orders exist
         // 3. No active cooldown
         if(!g_mobile_grid_built && !HasOurPositionsOrOrders() && g_mobile_check_cooldown <= 0)
         {
            PrintFormat("Auto-building grid for mobile position: %.2f lot %s", lot, (is_buy?"BUY":"SELL"));
            
            // Build grid based on mobile position direction
            // ★ Use Bottom Grid mode with AutoLot (same as Bottom Grid UI button)
            ENUM_ORDER_TYPE grid_type = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            OpenPositionsEx(grid_type, true, true);  // ← useAutoLot = TRUE, useBottomGrid = TRUE
            
            // Grid built flag and cooldown are set inside OpenPositionsEx()
            PrintFormat("Grid auto-built for mobile position ticket %I64u (Bottom Grid mode)", ticket);
         }
      }
      else
      {
         // Mobile position too small (≤ 0.02) - ignore it
         if(g_mobile_base_lot > 0.0)
         {
            PrintFormat("Mobile position lot %.2f <= 0.02 - ignoring (using symbol default)", lot);
            g_mobile_base_lot = 0.0;
            g_mobile_ticket = 0;
            g_mobile_grid_built = false;
            g_mobile_check_cooldown = 0;
         }
      }
   }
   else
   {
      // No external position found - reset mobile state
      if(g_mobile_base_lot > 0.0)
      {
         PrintFormat("Mobile position closed or not found - resetting mobile state");
      }
      g_mobile_base_lot = 0.0;
      g_mobile_ticket = 0;
      g_mobile_grid_built = false;
      g_mobile_check_cooldown = 0;
   }
}

void OnTick()
{
   // ★ Check for mobile/external lot first (with throttling)
   CheckAndUpdateMobileLot();
   
   // risk cap runtime guard
   EmergencyRiskCloseIfNeeded();

   CheckAmountExit();

   // Keep TP0 moving (only before TP1)
   if(UseServerTP && g_has_tp && !g_tp1_done)
      RebuildServerTP(false);

   // TP1 trigger check (pre-hit)
   if(UseTP1_PreClose && !g_tp1_done && g_has_tp)
   {
      UpdateTP1Line();
      if(IsTP1Triggered())
         ExecuteTP1Flow();
   }

   ShowGridInfo();
   UpdateUIButtonTexts();
}

//─────────────────────────────────────────────────────────────
// Hybrid Trailing by Timer (Dynamic TF: one level above chart)
//  - After TP1, can auto-arm (option)
//  - Update: new bar on (chart TF + 1 level)
//    M1->M5, M5->M15, M15->M30, M30->H1, H1->H4, H4->D1, etc
//  - SL = tighter of {ATR trail, prev bar 50% mid}
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!trailingEnabled) return;

   // ★ Dynamic TF: one level above chart TF
   ENUM_TIMEFRAMES trail_tf = GetTrailingTimeframe();
   
   datetime trail_time = iTime(_Symbol, trail_tf, 0);
   if(trail_time == 0) return;
   if(trail_time == g_lastTrailBarTime) return;
   g_lastTrailBarTime = trail_time;

   // Prev bar stats (bar index 1) from trailing TF
   double prevH = iHigh(_Symbol, trail_tf, 1);
   double prevL = iLow (_Symbol, trail_tf, 1);
   double prevMid = (prevH>0.0 && prevL>0.0) ? ((prevH + prevL) * 0.5) : 0.0;

   double atr = GetATR(_Symbol, trail_tf, ATR_H1_Period);
   if(atr <= 0.0) atr = TickSize();

   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long mag = PositionGetInteger(POSITION_MAGIC);
      if(mag != MagicGrid && mag != MagicMarket) continue;

      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double cur_sl    = PositionGetDouble(POSITION_SL);
      double cur_tp    = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool is_buy = (pos_type == POSITION_TYPE_BUY);
      double ref_price = is_buy ? bid : ask;

      // Candidate 1: ATR trail
      double sl_atr = is_buy ? (bid - atr * Hybrid_ATR_Mult)
                             : (ask + atr * Hybrid_ATR_Mult);

      // Candidate 2: prev bar mid (50%)
      double sl_mid = prevMid;

      // Choose tighter (more protective)
      double new_sl = cur_sl;

      if(is_buy)
      {
         double cand = sl_atr;
         if(Hybrid_UsePrevMid && sl_mid>0.0) cand = MathMax(cand, sl_mid);

         if(cur_sl == 0.0) new_sl = cand;
         else new_sl = MathMax(cur_sl, cand);

         new_sl = EnsureStopsLevelAway(ref_price, new_sl, true);

         if(cur_sl == 0.0 || new_sl > cur_sl + TickSize()*0.1)
            trade.PositionModify(ticket, new_sl, cur_tp);
      }
      else
      {
         double cand = sl_atr;
         if(Hybrid_UsePrevMid && sl_mid>0.0) cand = MathMin(cand, sl_mid);

         if(cur_sl == 0.0) new_sl = cand;
         else new_sl = MathMin(cur_sl, cand);

         new_sl = EnsureStopsLevelAway(ref_price, new_sl, false);

         if(cur_sl == 0.0 || new_sl < cur_sl - TickSize()*0.1)
            trade.PositionModify(ticket, new_sl, cur_tp);
      }

      Sleep(40);
   }
}
