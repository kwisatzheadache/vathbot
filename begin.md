Read the docs at: https://docs.polymarket.com/market-data/websocket/rtds

I want to begin a project. 

In steps.

Step 1: figure out how to find the latest btc updown markets
- for 5 minutes, they look like this: https://polymarket.com/event/btc-updown-5m-1778673300
- for 15 minutes, they look like this: https://polymarket.com/event/btc-updown-15m-1778601600

I want a function that will fetch the upcoming markets for both of these

Step 2: i want to record the data from them. This will involve streaming using websockets. 
For each of the events - we should monitor the event from 1-hour before the target datetime, until the market resolves (time interval + target starttime)

Ideally, we're getting the odds spread and everything that is available for the markets to stream.
Record them to a file locally for each market. I think we weill recombine them later, but for now, put them in seaparte areas for each.

Do these events capture bitcoin price data? we'll figure out what we want to do afterwards if not.


I think we'll want to use Elixir, since we're going to be streaming lots of sockets. 


Step 3: we're going to do some gathering of data. We'll want to run a (likely elixir) app for a few days/weeks to gather this event data. 

step 4: we'll want to do analysis  
- Simple analysis of event data: how often the spreads change etc. 

The event data, if it does not contain btc info, will have to be joined to a btc info dataset. So if we don't have that, we'll also want to set up a websocket to capture btc price info.

Once we have that: we're going to look at the relationship of btc price in time to the odds spreads of the polymarket events. So we'll want to build out too,ing that connects those two for testing. 

That's enough for now, lets get this set up and collecting data. 