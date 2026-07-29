// scalingPlan.bicep — simple ramp-up/peak/ramp-down/off-peak schedule for the pilot
// Proves the cost-optimization story: scale-to-minimum outside working hours.
param namePrefix string
param location string
param hostPoolId string

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2023-09-05' = {
  name: '${namePrefix}-scaling-pilot'
  location: location
  properties: {
    timeZone: 'GMT Standard Time'
    hostPoolType: 'Pooled'
    schedules: [
      {
        name: 'weekdays'
        daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
        rampUpStartTime: { hour: 7, minute: 30 }
        rampUpLoadBalancingAlgorithm: 'BreadthFirst'
        rampUpMinimumHostsPct: 50
        rampUpCapacityThresholdPct: 80
        peakStartTime: { hour: 9, minute: 0 }
        peakLoadBalancingAlgorithm: 'BreadthFirst'
        rampDownStartTime: { hour: 17, minute: 30 }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 0
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'Session ending soon, please save your work.'
        offPeakStartTime: { hour: 19, minute: 0 }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolId
        scalingPlanEnabled: true
      }
    ]
  }
}

output scalingPlanId string = scalingPlan.id
