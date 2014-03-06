//
//  MessageBoard.m
//  VTHacks
//
//  Created by Carlos Second Admin on 3/2/14.
//  Copyright (c) 2014 Vincent Ngo. All rights reserved.
//

#import "MessageBoard.h"
#import "Constants.h"

#import <AWSRuntime/AWSRuntime.h>


// This singleton class provides all the functionality to manipulate the Amazon
// SNS Topic and Amazon SQS Queue used in this sample application.
@implementation MessageBoard


static MessageBoard *_instance = nil;

+(MessageBoard *)instance
{
    if (!_instance) {
        @synchronized([MessageBoard class])
        {
            if (!_instance) {
                _instance = [self new];
            }
        }
    }
    
    return _instance;
}


-(id)init
{
    self = [super init];
    NSLog(@"~~~~~ Calling [MessageBoard init]");
    if (self != nil) {
        snsClient = [[AmazonSNSClient alloc] initWithAccessKey:ACCESS_KEY_ID withSecretKey:SECRET_KEY];
        snsClient.endpoint = [AmazonEndpoints snsEndpoint:US_EAST_1];
        
        sqsClient = [[AmazonSQSClient alloc] initWithAccessKey:ACCESS_KEY_ID withSecretKey:SECRET_KEY];
        sqsClient.endpoint = [AmazonEndpoints sqsEndpoint:US_EAST_1];
        
        // Find the Topic for this App or create one.
        topicARN = [self findTopicArn];
        if (topicARN == nil) {
            topicARN = [self createTopic];
        }
        
        // Find the Queue for this App or create one.
        queueUrl = [self findQueueUrl];
        if (queueUrl == nil) {
            queueUrl = [self createQueue];
            
            // Allow time for the queue to be created.
            [NSThread sleepForTimeInterval:4.0];
            
            [self subscribeQueue];
        }
        
        // Find endpointARN for this device if there is one.
        endpointARN = [self findEndpointARN];
        [self createApplicationEndpoint];
        
        
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(queue, ^{
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
            });
            
            NSMutableArray *msgs = [[MessageBoard instance] getMessagesFromQueue];
            NSLog(@"%@", msgs);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            });
        });
    }
    
    return self;
}


- (void)subscribeDevice:(id)sender {
    
#if TARGET_IPHONE_SIMULATOR
    [[Constants universalAlertsWithTitle:@"Unable to Subscribe Device" andMessage:@"Push notifications are not supported in the simulator."] show];
    return;
#endif
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        });
        
        if ([[MessageBoard instance] subscribeDevice]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                
                [[Constants universalAlertsWithTitle:@"Subscription succeed" andMessage:nil] show];
            });
        }
        
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
        });
    });
    
}



-(NSString *)createTopic
{
    SNSCreateTopicRequest *ctr = [[SNSCreateTopicRequest alloc] initWithName:TOPIC_NAME];
    SNSCreateTopicResponse *response = [snsClient createTopic:ctr];
    if(response.error != nil)
    {
        NSLog(@"SNSCreateTopicResponse Error: %@", response.error);
        return nil;
    }
    
    // Adding the DisplayName attribute to the Topic allows for SMS notifications.
    SNSSetTopicAttributesRequest *st = [[SNSSetTopicAttributesRequest alloc] initWithTopicArn:response.topicArn andAttributeName:@"VTHacks" andAttributeValue:TOPIC_NAME];
    SNSSetTopicAttributesResponse *setTopicAttributesResponse = [snsClient setTopicAttributes:st];
    if(setTopicAttributesResponse.error != nil)
    {
        NSLog(@"Error: %@", setTopicAttributesResponse.error);
        return nil;
    }
    
    return response.topicArn;
}

-(bool)createApplicationEndpoint
{
    
    NSString *deviceToken = [[NSUserDefaults standardUserDefaults] stringForKey:@"myDeviceToken"];
    if (!deviceToken) {
        [[Constants universalAlertsWithTitle:@"deviceToken not found!" andMessage:@"Device may fail to register with Apple's Notification Service, please check debug window for details"] show];
    }
    
    SNSCreatePlatformEndpointRequest *endpointReq = [[SNSCreatePlatformEndpointRequest alloc] init];
    endpointReq.platformApplicationArn = PLATFORM_APPLICATION_ARN;
    endpointReq.token = deviceToken;
    
    SNSCreatePlatformEndpointResponse *endpointResponse = [snsClient createPlatformEndpoint:endpointReq];
    if (endpointResponse.error != nil)
    {
        NSLog(@"Error: %@", endpointResponse.error);
        [[Constants universalAlertsWithTitle:@"CreateApplicationEndpoint Error" andMessage:endpointResponse.error.userInfo.description] show];
        return NO;
    }
    
    endpointARN = endpointResponse.endpointArn;
    [[NSUserDefaults standardUserDefaults] setObject:endpointResponse.endpointArn forKey:@"DEVICE_ENDPOINT"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    return YES;
}

-(bool)subscribeDevice
{
    if (endpointARN == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [[Constants universalAlertsWithTitle:@"endpointARN not found!" andMessage:@"Please create an endpoint for this device before subscribe to topic"] show];
        });
        return NO;
    }
    
    SNSSubscribeRequest *sr = [[SNSSubscribeRequest alloc] initWithTopicArn:topicARN andProtocol:@"application" andEndpoint:endpointARN];
    SNSSubscribeResponse *subscribeResponse = [snsClient subscribe:sr];
    if(subscribeResponse.error != nil)
    {
        NSLog(@"Error: %@", subscribeResponse.error);
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [[Constants universalAlertsWithTitle:@"Subscription Error" andMessage:subscribeResponse.error.userInfo.description] show];
        });
        
        return NO;
    }
    
    return YES;
}

-(void)subscribeEmail:(NSString *)emailAddress
{
    SNSSubscribeRequest *sr = [[SNSSubscribeRequest alloc] initWithTopicArn:topicARN andProtocol:@"email" andEndpoint:emailAddress];
    SNSSubscribeResponse *subscribeResponse = [snsClient subscribe:sr];
    if(subscribeResponse.error != nil)
    {
        NSLog(@"Error: %@", subscribeResponse.error);
    }
}

-(void)subscribeSms:(NSString *)smsNumber
{
    SNSSubscribeRequest *sr = [[SNSSubscribeRequest alloc] initWithTopicArn:topicARN andProtocol:@"sms" andEndpoint:smsNumber];
    SNSSubscribeResponse *subscribeResponse = [snsClient subscribe:sr];
    if(subscribeResponse.error != nil)
    {
        NSLog(@"Error: %@", subscribeResponse.error);
    }
}

-(void)subscribeQueue
{
    NSString *queueArn = [self getQueueArn:queueUrl];
    
    SNSSubscribeRequest *request = [[SNSSubscribeRequest alloc] initWithTopicArn:topicARN andProtocol:@"sqs" andEndpoint:queueArn];
    SNSSubscribeResponse *subscribeResponse = [snsClient subscribe:request];
    if(subscribeResponse.error != nil)
    {
        NSLog(@"Error: %@", subscribeResponse.error);
    }
}

-(NSMutableArray *)listEndpoints
{
    SNSListEndpointsByPlatformApplicationRequest *le = [[SNSListEndpointsByPlatformApplicationRequest alloc] init];
    le.platformApplicationArn = PLATFORM_APPLICATION_ARN;
    SNSListEndpointsByPlatformApplicationResponse *response = [snsClient listEndpointsByPlatformApplication:le];
    if(response.error != nil)
    {
        NSLog(@"SNSListEndpointsByPlatformApplicationResponse Error: %@", response.error);
        return [NSMutableArray array];
    }
    
    return response.endpoints;
}

-(NSMutableArray *)listSubscribers
{
    SNSListSubscriptionsByTopicRequest  *ls       = [[SNSListSubscriptionsByTopicRequest alloc] initWithTopicArn:topicARN];
    SNSListSubscriptionsByTopicResponse *response = [snsClient listSubscriptionsByTopic:ls];
    if(response.error != nil)
    {
        NSLog(@"Error: %@", response.error);
        return [NSMutableArray array];
    }
    
    return response.subscriptions;
}

// update attributes for an endpoint
-(void)updateEndpointAttributesWithendPointARN:(NSString *)endpointArn Attributes:(NSMutableDictionary *)attributeDic {
    SNSSetEndpointAttributesRequest *req = [[SNSSetEndpointAttributesRequest alloc] init];
    req.endpointArn = endpointArn;
    req.attributes = attributeDic;
    SNSSetEndpointAttributesResponse *response = [snsClient setEndpointAttributes:req];
    if (response.error != nil) {
        NSLog(@"Error: %@", response.error);
    }
    
}
// remove an endpoint from endpoints list
-(void)removeEndpoint:(NSString *)endpointArn
{
    SNSDeleteEndpointRequest *deleteEndpointReq = [[SNSDeleteEndpointRequest alloc] init];
    deleteEndpointReq.endpointArn = endpointArn;
    SNSDeleteEndpointResponse *response = [snsClient deleteEndpoint:deleteEndpointReq];
    if (response.error != nil)
    {
        NSLog(@"Error: %@", response.error);
    }
}
// Unscribe an endpoint from the topic.
-(void)removeSubscriber:(NSString *)subscriptionArn
{
    SNSUnsubscribeRequest *unsubscribeRequest = [[SNSUnsubscribeRequest alloc] initWithSubscriptionArn:subscriptionArn];
    SNSUnsubscribeResponse *unsubscribeResponse = [snsClient unsubscribe:unsubscribeRequest];
    if(unsubscribeResponse.error != nil)
    {
        NSLog(@"SNSUnsubscribeResponse Error: %@", unsubscribeResponse.error);
    }
}

//Push a message to Mobile Device
-(bool)pushToMobile:(NSString*)theMessage
{
    SNSPublishRequest *pr = [[SNSPublishRequest alloc] init];
    pr.targetArn = endpointARN;
    pr.message = theMessage;
    
    SNSPublishResponse *publishResponse = [snsClient publish:pr];
    if(publishResponse.error != nil)
    {
        NSLog(@"Error: %@", publishResponse.error);
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [[Constants universalAlertsWithTitle:@"Push to Mobile Error" andMessage:publishResponse.error.userInfo.description] show];
        });
        
        return NO;
    }
    return YES;
}

// Post a notification to the topic.
-(void)post:(NSString *)theMessage;
{
    if ([theMessage isEqualToString:@"wipe"]) {
        [self deleteQueue];
        [self deleteTopic];
    }
    else {
        SNSPublishRequest *pr = [[SNSPublishRequest alloc] initWithTopicArn:topicARN andMessage:theMessage];
        SNSPublishResponse *publishResponse = [snsClient publish:pr];
        if(publishResponse.error != nil)
        {
            NSLog(@"Error: %@", publishResponse.error);
        }
    }
}

-(void)deleteTopic
{
    SNSDeleteTopicRequest *dtr = [[SNSDeleteTopicRequest alloc] initWithTopicArn:topicARN];
    SNSDeleteTopicResponse *deleteTopicResponse = [snsClient deleteTopic:dtr];
    if(deleteTopicResponse.error != nil)
    {
        NSLog(@"Error: %@", deleteTopicResponse.error);
    }
}

-(void)deleteQueue
{
    SQSDeleteQueueRequest *request = [[SQSDeleteQueueRequest alloc] initWithQueueUrl:queueUrl];
    SQSDeleteQueueResponse *deleteQueueResponse = [sqsClient deleteQueue:request];
    if(deleteQueueResponse.error != nil)
    {
        NSLog(@"Error: %@", deleteQueueResponse.error);
    }
}

-(NSString *)createQueue
{
    SQSCreateQueueRequest *cqr = [[SQSCreateQueueRequest alloc] initWithQueueName:QUEUE_NAME];
    SQSCreateQueueResponse *response = [sqsClient createQueue:cqr];
    if(response.error != nil)
    {
        NSLog(@"Error: %@", response.error);
        return nil;
    }
    
    NSString *queueArn = [self getQueueArn:response.queueUrl];
    [self addPolicyToQueueForTopic:response.queueUrl queueArn:queueArn];
    [self changeVisibilityTimeoutForQueue:response.queueUrl toSeconds:30]; //Default is 30, can have range between 0 - 43200 seconds
    
    return response.queueUrl;
}

-(NSMutableArray *)getMessagesFromQueue
{
    SQSReceiveMessageRequest *rmr = [[SQSReceiveMessageRequest alloc] initWithQueueUrl:queueUrl];
    rmr.maxNumberOfMessages = [NSNumber numberWithInt:10];
    rmr.visibilityTimeout   = [NSNumber numberWithInt:10];
    
    SQSReceiveMessageResponse *response    = nil;
    NSMutableArray *allMessages = [NSMutableArray array];
    do {
        response = [sqsClient receiveMessage:rmr];
        if(response.error != nil)
        {
            NSLog(@"Error: %@", response.error);
            return [NSMutableArray array];
        }
        
        [allMessages addObjectsFromArray:response.messages];
        [NSThread sleepForTimeInterval:0.2];
    } while ( [response.messages count] != 0);
    
    return allMessages;
}

-(void)deleteMessageFromQueue:(SQSMessage *)message
{
    SQSDeleteMessageRequest *request = [[SQSDeleteMessageRequest alloc] initWithQueueUrl:queueUrl andReceiptHandle:message.receiptHandle];
    SQSDeleteMessageResponse *deleteMessageResponse = [sqsClient deleteMessage:request];
    if(deleteMessageResponse.error != nil)
    {
        NSLog(@"Error: %@", deleteMessageResponse.error);
    }
}

// Get the QueueArn attribute from the Queue.  The QueueArn is necessary for create a policy on the queue
// that allows for messages from the Amazon SNS Topic.
-(NSString *)getQueueArn:(NSString *)theQueueUrl
{
    SQSGetQueueAttributesRequest *gqar = [[SQSGetQueueAttributesRequest alloc] initWithQueueUrl:theQueueUrl];
    [gqar.attributeNames addObject:@"QueueArn"];
    
    SQSGetQueueAttributesResponse *response = [sqsClient getQueueAttributes:gqar];
    if(response.error != nil)
    {
        NSLog(@"Error: %@", response.error);
        return nil;
    }
    
    return [response.attributes valueForKey:@"QueueArn"];
}

// Change Visibility Timeout for a queue.
// For more details about Visibility timeout, please visit
// http://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/AboutVT.html
-(void)changeVisibilityTimeoutForQueue:(NSString*)theQueueUrl toSeconds:(int)seconds{
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    [attributes setValue:[NSNumber numberWithInt:seconds] forKey:@"VisibilityTimeout"];
    
    SQSSetQueueAttributesRequest *request = [[SQSSetQueueAttributesRequest alloc] initWithQueueUrl:theQueueUrl andAttributes:attributes];
    SQSSetQueueAttributesResponse *setQueueAttributesResponse = [sqsClient setQueueAttributes:request];
    if(setQueueAttributesResponse.error != nil)
    {
        NSLog(@"Error: %@", setQueueAttributesResponse.error);
    }
    // It can take some time for policy to propagate to the queue.
}


// Add a policy to a specific queue by setting the queue's Policy attribute.
// Assigning a policy to the queue is necessary as described in Amazon SNS' FAQ:
// http://aws.amazon.com/sns/faqs/#26
-(void)addPolicyToQueueForTopic:(NSString *)theQueueUrl queueArn:(NSString *)queueArn
{
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    [attributes setValue:[self generateSqsPolicyForTopic:queueArn] forKey:@"Policy"];
    
    SQSSetQueueAttributesRequest *request = [[SQSSetQueueAttributesRequest alloc] initWithQueueUrl:theQueueUrl andAttributes:attributes];
    SQSSetQueueAttributesResponse *setQueueAttributesResponse = [sqsClient setQueueAttributes:request];
    if(setQueueAttributesResponse.error != nil)
    {
        NSLog(@"Error: %@", setQueueAttributesResponse.error);
    }
    // It can take some time for policy to propagate to the queue.
}

// Creates the policy object that is necessary to allow the topic to send message to the queue.  The topic will
// send all topic notifications to the queue.
-(NSString *)generateSqsPolicyForTopic:(NSString *)queueArn
{
    NSDictionary *policyDic = [NSDictionary dictionaryWithObjectsAndKeys:
                               @"2008-10-17", @"Version",
                               [NSString stringWithFormat:@"%@/policyId", queueArn], @"Id",
                               [NSArray arrayWithObjects:[NSDictionary dictionaryWithObjectsAndKeys:
                                                          [NSString stringWithFormat:@"%@/statementId", queueArn], @"Sid",
                                                          @"Allow", @"Effect",
                                                          [NSDictionary dictionaryWithObject:@"*" forKey:@"AWS"], @"Principal",
                                                          @"SQS:SendMessage", @"Action",
                                                          queueArn, @"Resource",
                                                          [NSDictionary dictionaryWithObject:
                                                           [NSDictionary dictionaryWithObject:topicARN forKey:@"aws:SourceArn"] forKey:@"StringEquals"], @"Condition",
                                                          nil],
                                nil], @"Statement",
                               nil];
    AWS_SBJsonWriter *writer = [AWS_SBJsonWriter new];
    
    return [writer stringWithObject:policyDic];
}

// Determines if a topic exists with the given topic name.
// The topic name is assigned in the Constants.h file.
-(NSString *)findTopicArn
{
    NSString *topicNameToFind = [NSString stringWithFormat:@":%@", TOPIC_NAME];
    NSString *nextToken = nil;
    do
    {
        SNSListTopicsRequest *listTopicsRequest = [[SNSListTopicsRequest alloc] initWithNextToken:nextToken];
        SNSListTopicsResponse *response = [snsClient listTopics:listTopicsRequest];
        if(response.error != nil)
        {
            NSLog(@"SNSListTopicsResponse Error: %@", response.error);
            return nil;
        }
        
        for (SNSTopic *topic in response.topics) {
            if ( [topic.topicArn hasSuffix:topicNameToFind]) {
                return topic.topicArn;
            }
        }
        
        nextToken = response.nextToken;
    } while (nextToken != nil);
    
    return nil;
}

// Determine if a queue exists with the given queue name.
// The queue name is assigned in the Constants.h file.
-(NSString *)findQueueUrl
{
    NSString *queueNameToFind = [NSString stringWithFormat:@"/%@", QUEUE_NAME];
    
    SQSListQueuesRequest *request = [SQSListQueuesRequest new];
    SQSListQueuesResponse *queuesResponse = [sqsClient listQueues:request];
    if(queuesResponse.error != nil)
    {
        NSLog(@"SQSListQueuesResponse Error: %@", queuesResponse.error);
        return nil;
    }
    
    for (NSString *qUrl in queuesResponse.queueUrls) {
        if ( [qUrl hasSuffix:queueNameToFind]) {
            return qUrl;
        }
    }
    
    return nil;
}

-(NSString *)findEndpointARN
{
    if (endpointARN != nil) {
        return endpointARN;
    } else
    {
        NSString *storedEndpoint = [[NSUserDefaults standardUserDefaults] stringForKey:@"DEVICE_ENDPOINT"];
        return storedEndpoint;
    }
    
}
-(void)dealloc
{

}

@end
