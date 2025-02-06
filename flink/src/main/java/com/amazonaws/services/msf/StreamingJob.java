package com.amazonaws.services.msf;

import com.amazonaws.services.kinesisanalytics.runtime.KinesisAnalyticsRuntime;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.AggregateFunction;
import org.apache.flink.api.common.serialization.SerializationSchema;
import org.apache.flink.api.common.typeinfo.TypeInformation;
import org.apache.flink.api.connector.source.util.ratelimit.RateLimiterStrategy;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.connector.datagen.source.DataGeneratorSource;
import org.apache.flink.connector.kinesis.sink.KinesisStreamsSink;
import org.apache.flink.formats.json.JsonSerializationSchema;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.LocalStreamEnvironment;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.windowing.ProcessWindowFunction;
import org.apache.flink.streaming.api.windowing.assigners.TumblingProcessingTimeWindows;
import org.apache.flink.streaming.api.windowing.time.Time;
import org.apache.flink.streaming.api.windowing.windows.TimeWindow;
import org.apache.flink.util.Collector;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.io.IOException;
import java.sql.Timestamp;
import java.util.Map;
import java.util.Properties;

public class StreamingJob {

    private static final Logger LOGGER = LogManager.getLogger(StreamingJob.class);

    // Name of the local JSON resource with the application properties in the same format as they are received from the Amazon Managed Service for Apache Flink runtime
    private static final String LOCAL_APPLICATION_PROPERTIES_RESOURCE = "flink-application-properties-dev.json";

    // Create ObjectMapper instance to serialise POJOs into JSONs
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    private static boolean isLocal(StreamExecutionEnvironment env) {
        return env instanceof LocalStreamEnvironment;
    }

    /**
     * Load application properties from Amazon Managed Service for Apache Flink runtime or from a local resource, when the environment is local
     */
    private static Map<String, Properties> loadApplicationProperties(StreamExecutionEnvironment env) throws IOException {
        if (isLocal(env)) {
            LOGGER.info("Loading application properties from '{}'", LOCAL_APPLICATION_PROPERTIES_RESOURCE);
            return KinesisAnalyticsRuntime.getApplicationProperties(
                    StreamingJob.class.getClassLoader()
                            .getResource(LOCAL_APPLICATION_PROPERTIES_RESOURCE).getPath());
        } else {
            LOGGER.info("Loading application properties from Amazon Managed Service for Apache Flink");
            return KinesisAnalyticsRuntime.getApplicationProperties();
        }
    }


    private static DataGeneratorSource<StockPrice> getStockPriceDataGeneratorSource() {
        long recordPerSecond = 100;
        return new DataGeneratorSource<>(
                new StockPriceGeneratorFunction(),
                Long.MAX_VALUE,
                RateLimiterStrategy.perSecond(recordPerSecond),
                TypeInformation.of(StockPrice.class));
    }

    private static <T> KinesisStreamsSink<T> getKinesisSink(Properties outputProperties, final SerializationSchema<T> serializationSchema) {
        final String outputStreamName = outputProperties.getProperty("stream.name");
        return KinesisStreamsSink.<T>builder()
                .setStreamName(outputStreamName)
                .setKinesisClientProperties(outputProperties)
                .setSerializationSchema(serializationSchema)
                .setPartitionKeyGenerator(element -> String.valueOf(element.hashCode()))
                .build();
    }

    public static void main(String[] args) throws Exception {
        // Set up the streaming execution environment
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        final Map<String, Properties> applicationProperties = loadApplicationProperties(env);

        // Local dev specific settings
        if (isLocal(env)) {
            // Checkpointing and parallelism are set by Amazon Managed Service for Apache Flink when running on AWS
            env.enableCheckpointing(60000);
            env.setParallelism(2);
        }

        // Source
        DataGeneratorSource<StockPrice> source = getStockPriceDataGeneratorSource();

        // DataStream from Source
        DataStream<StockPrice> sourceStream = env.fromSource(
                        source,
                        WatermarkStrategy.noWatermarks(),
                        "data-generator")
                .uid("source-stream")
                .setParallelism(1);

        // Stateful computation
        DataStream<StockPrice> windowedStream = sourceStream
                .keyBy(stockPrice -> stockPrice.getTicker())
                .window(TumblingProcessingTimeWindows.of(Time.seconds(10)))
                .aggregate(new AggregateFunction<StockPrice, Tuple2<Double, Long>, Double>() {
                    @Override
                    public Tuple2<Double, Long> createAccumulator() {
                        return new Tuple2<>(0.0, 0L);
                    }

                    @Override
                    public Tuple2<Double, Long> add(StockPrice value, Tuple2<Double, Long> accumulator) {
                        return new Tuple2<>(accumulator.f0 + value.getPrice(), accumulator.f1 + 1);
                    }

                    @Override
                    public Double getResult(Tuple2<Double, Long> accumulator) {
                        return (Double) (accumulator.f0 / accumulator.f1); // Calculate the average
                    }

                    @Override
                    public Tuple2<Double, Long> merge(Tuple2<Double, Long> a, Tuple2<Double, Long> b) {
                        return new Tuple2<>(a.f0 + b.f0, a.f1 + b.f1);
                    }
                }, new ProcessWindowFunction<Double, StockPrice, String, TimeWindow>() {
                    @Override
                    public void process(
                            String ticker,
                            Context context,
                            Iterable<Double> elements,
                            Collector<StockPrice> out) {
                        Double avgPrice = elements.iterator().next();
                        StockPrice result = new StockPrice();
                        result.setEventTime(new Timestamp(context.window().getStart()));
                        result.setTicker(ticker);
                        result.setPrice(avgPrice);
                        out.collect(result);
                    }
                }).uid("windowed-avg-price");

        // Sink
        KinesisStreamsSink<StockPrice> sink = getKinesisSink(applicationProperties.get("OutputStream0"), new JsonSerializationSchema<>());

        // DataStream to Sink
        windowedStream.sinkTo(sink).uid("kinesis-sink");

        env.execute("Flink Streaming Job");
    }
}
