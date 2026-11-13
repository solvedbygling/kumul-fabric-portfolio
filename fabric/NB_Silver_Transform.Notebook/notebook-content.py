# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "c2090b46-82ea-4102-bd6d-4b0d72f21b25",
# META       "default_lakehouse_name": "LH_Silver",
# META       "default_lakehouse_workspace_id": "66b1b5c1-e398-4a6f-a08e-f70de76376c8",
# META       "known_lakehouses": [
# META         {
# META           "id": "c2090b46-82ea-4102-bd6d-4b0d72f21b25"
# META         },
# META         {
# META           "id": "f12b25a2-de09-462c-b44a-46de210c16dc"
# META         }
# META       ]
# META     }
# META   }
# META }

# CELL ********************

from pyspark.sql import functions as F
from pyspark.sql import Window

BRONZE = "LH_Bronze"   

def bronze(table):
    return spark.read.table(f"{BRONZE}.{table}")

dq_log = []
def log_dq(table, rule, count):
    dq_log.append((table, rule, int(count)))
    print(f"{table:<18} {rule:<42} {count:>6}")

def write_silver(df, name):
    (df.withColumn("_silver_loaded_at", F.current_timestamp())
       .write.mode("overwrite").option("overwriteSchema", "true")
       .saveAsTable(name))
    print(f"✔ {name}: {spark.read.table(name).count()} rows")


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

write_silver(bronze("Entity"), "Entity")

warehouse = (bronze("Warehouse")
    .withColumn("WarehouseName", F.trim("WarehouseName"))
    .withColumn("City", F.trim("City")))
write_silver(warehouse, "Warehouse")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

p = bronze("Product")
name_t = F.trim("ProductName")

log_dq("Product", "Name lower-case / trailing spaces",
       p.filter((F.col("ProductName") != name_t) | (name_t == F.lower(name_t))).count())
log_dq("Product", "Zero list price", p.filter(F.col("ListPriceAUD") == 0).count())

product = (p
    .withColumn("ProductName", F.when(name_t == F.lower(name_t), F.initcap(name_t)).otherwise(name_t))
    .withColumn("IsPriceMissing", F.col("ListPriceAUD") == 0))
write_silver(product, "Product")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

c = bronze("Customer")
canonical_cities = ["Brisbane","Cairns","Townsville","Gold Coast","Darwin","Sydney",
                    "Port Moresby","Lae","Mount Hagen","Madang","Kokopo","Alotau"]

log_dq("Customer", "Name upper-case / extra spaces",
       c.filter((F.col("CustomerName") != F.trim("CustomerName")) |
                (F.col("CustomerName") == F.upper("CustomerName"))).count())
log_dq("Customer", "Non-standard city spelling", c.filter(~F.col("City").isin(canonical_cities)).count())
log_dq("Customer", "Missing customer type", c.filter(F.col("CustomerType").isNull()).count())

name_clean = F.regexp_replace(F.trim("CustomerName"), r"\s+", " ")
city_lc = F.lower(F.trim("City"))

c1 = (c
    .withColumn("CustomerName", F.when(name_clean == F.upper(name_clean), F.initcap(name_clean)).otherwise(name_clean))
    .withColumn("City", F.when(city_lc.isin("pom", "pt. moresby", "pt moresby"), F.lit("Port Moresby"))
                         .otherwise(F.initcap(city_lc)))
    .withColumn("CustomerType", F.coalesce(F.col("CustomerType"), F.lit("Unknown"))))

# Duplicate detection: same entity + same name ignoring case/punctuation
c2 = (c1.withColumn("_match_key", F.regexp_replace(F.lower("CustomerName"), r"[^a-z0-9]", ""))
        .withColumn("MasterCustomerID", F.min("CustomerID").over(Window.partitionBy("EntityID", "_match_key"))))

log_dq("Customer", "Duplicate customers merged",
       c2.filter(F.col("CustomerID") != F.col("MasterCustomerID")).count())

write_silver(c2.select(F.col("CustomerID").alias("SourceCustomerID"), "MasterCustomerID"), "CustomerKeyMap")
write_silver(c2.filter(F.col("CustomerID") == F.col("MasterCustomerID")).drop("_match_key", "MasterCustomerID"), "Customer")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

h = bronze("SalesOrderHeader")
km = spark.read.table("CustomerKeyMap")
ent = spark.read.table("Entity").select("EntityID", "BaseCurrency")
status_clean = F.initcap(F.trim("OrderStatus"))
date_gap = F.abs(F.datediff("OrderDate", F.to_date("CreatedAt")))

log_dq("SalesOrderHeader", "Status casing / whitespace", h.filter(F.col("OrderStatus") != status_clean).count())
log_dq("SalesOrderHeader", "Missing currency code", h.filter(F.col("CurrencyCode").isNull()).count())
log_dq("SalesOrderHeader", "Order date >1yr from system timestamp", h.filter(date_gap > 365).count())
log_dq("SalesOrderHeader", "Shipped with no ship date",
       h.filter((status_clean == "Shipped") & F.col("ShippedDate").isNull()).count())
log_dq("SalesOrderHeader", "Orders re-pointed to master customer",
       h.join(km.filter("SourceCustomerID != MasterCustomerID"), h.CustomerID == km.SourceCustomerID).count())

header = (h
    .withColumn("OrderStatus", status_clean)
    .join(F.broadcast(ent), "EntityID", "left")
    .withColumn("CurrencyCode", F.coalesce("CurrencyCode", "BaseCurrency")).drop("BaseCurrency")
    .withColumn("IsOrderDateCorrected", date_gap > 365)
    .withColumn("OrderDate", F.when(F.col("IsOrderDateCorrected"), F.to_date("CreatedAt")).otherwise(F.col("OrderDate")))
    .withColumn("IsShipDateImputed", (F.col("OrderStatus") == "Shipped") & F.col("ShippedDate").isNull())
    .withColumn("ShippedDate", F.when(F.col("IsShipDateImputed"), F.to_date("ModifiedAt")).otherwise(F.col("ShippedDate")))
    .join(F.broadcast(km), F.col("CustomerID") == F.col("SourceCustomerID"), "left")
    .withColumn("CustomerID", F.coalesce("MasterCustomerID", "CustomerID"))
    .drop("SourceCustomerID", "MasterCustomerID"))
write_silver(header, "SalesOrderHeader")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

l = bronze("SalesOrderLine")

log_dq("SalesOrderLine", "Negative quantity (returns)", l.filter(F.col("Quantity") < 0).count())
log_dq("SalesOrderLine", "Zero unit price", l.filter(F.col("UnitPrice") == 0).count())
log_dq("SalesOrderLine", "Orphan lines (no header)",
       l.join(spark.read.table("SalesOrderHeader"), "SalesOrderID", "left_anti").count())

line = (l
    .withColumn("IsReturn", F.col("Quantity") < 0)
    .withColumn("LineAmountLocal",
                F.round(F.col("Quantity") * F.col("UnitPrice") * (1 - F.col("DiscountPct") / 100), 2)))
write_silver(line, "SalesOrderLine")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

FX_PATH = "abfss://66b1b5c1-e398-4a6f-a08e-f70de76376c8@onelake.dfs.fabric.microsoft.com/f12b25a2-de09-462c-b44a-46de210c16dc/Files/treasury/fx_rates_monthly.csv"

fx = (spark.read.option("header", True).csv(FX_PATH)
        .withColumn("RateMonth", F.to_date("RateMonth"))
        .withColumn("CurrencyCode", F.upper(F.trim("CurrencyCode")))
        .withColumn("AUDPerUnit", F.col("AUDPerUnit").cast("decimal(12,6)")))

log_dq("FxRate", "Rows with missing rate", fx.filter(F.col("AUDPerUnit").isNull()).count())
write_silver(fx, "FxRate")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

dq_df = (spark.createDataFrame(dq_log, "TableName string, Rule string, RowsAffected int")
              .withColumn("RunAt", F.current_timestamp()))
dq_df.write.mode("append").saveAsTable("DataQualityLog")
display(dq_df)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

import sempy.fabric as fabric

client = fabric.FabricRestClient()
ws_id = fabric.get_workspace_id()
endpoints = client.get(f"/v1/workspaces/{ws_id}/sqlEndpoints").json()["value"]
ep = next(e for e in endpoints if e["displayName"] == "LH_Silver")
resp = client.post(f"/v1/workspaces/{ws_id}/sqlEndpoints/{ep['id']}/refreshMetadata", json={})
print("SQL endpoint refresh requested:", resp.status_code)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
